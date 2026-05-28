# frozen_string_literal: true

module PSX
  # CD-ROM controller. Implements enough of the real hardware to let the
  # SCPH1001 BIOS boot from a .bin/.cue image: SetLoc / Read / Pause / Seek
  # / GetLoc / GetTN / GetTD / GetID / Init / SetMode, plus a data FIFO that
  # delivers the 2048-byte user-data slice of each sector through both
  # programmed I/O and DMA channel 3.
  #
  # Timing model is approximate. Command-to-response delay is ~50K CPU
  # cycles (well below a frame so the BIOS' polls don't time out). Sector
  # cadence is 33.8688 MHz / 75 ≈ 451584 cycles at 1× and half that at 2×.
  # Real hardware adds wait states and seek latency we don't model.
  class CDROM
    # Status register (0x1F801800 read) bits.
    STAT_INDEX_MASK              = 0x03
    STAT_ADPCM_BUSY              = 0x04
    STAT_PARAMETER_FIFO_EMPTY    = 0x08
    STAT_PARAMETER_FIFO_NOT_FULL = 0x10
    STAT_RESPONSE_FIFO_NOT_EMPTY = 0x20
    STAT_DATA_FIFO_NOT_EMPTY     = 0x40
    STAT_BUSY                    = 0x80

    # CDROM "stat" byte bits (returned in INT3 responses).
    SF_ERROR        = 1 << 0
    SF_MOTOR_ON     = 1 << 1
    SF_SEEK_ERROR   = 1 << 2
    SF_ID_ERROR     = 1 << 3
    SF_SHELL_OPEN   = 1 << 4
    SF_READING      = 1 << 5
    SF_SEEKING      = 1 << 6
    SF_PLAYING_CDDA = 1 << 7

    ERROR_REASON_INVALID_COMMAND = 0x40
    ERROR_REASON_INVALID_ARGUMENT = 0x10
    ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS = 0x20
    ERROR_REASON_NOT_READY = 0x80

    # Timing constants (in CPU cycles).
    CYCLES_PER_SECTOR_1X = 33_868_800 / 75
    CYCLES_PER_SECTOR_2X = CYCLES_PER_SECTOR_1X / 2
    CYCLES_PER_RESPONSE  = 20_000
    # First sector after a seek arrives quickly — the drive pre-buffers
    # during SeekL, so when ReadN starts streaming the first INT1 lands
    # almost immediately. Subsequent sectors space out at the real cadence.
    CYCLES_FIRST_SECTOR  = 30_000
    CYCLES_FAR_READ_SEEK = 8_000_000
    WHOLE_SECTOR_FILTER_PREFIX_BYTES = 44

    DEFAULT_STAT_DISC    = SF_MOTOR_ON
    DEFAULT_STAT_NO_DISC = SF_SHELL_OPEN
    COMMAND_PARAMETER_COUNTS = {
      0x01 => 0..0,   # GetStat
      0x02 => 3..3,   # SetLoc
      0x03 => 0..1,   # Play
      0x04 => 0..0,   # Forward
      0x05 => 0..0,   # Backward
      0x06 => 0..0,   # ReadN
      0x07 => 0..0,   # MotorOn/Standby
      0x08 => 0..0,   # Stop
      0x09 => 0..0,   # Pause
      0x0A => 0..0,   # Init
      0x0B => 0..0,   # Mute
      0x0C => 0..0,   # Demute
      0x0D => 2..2,   # SetFilter
      0x0E => 1..1,   # SetMode
      0x0F => 0..0,   # GetParam
      0x10 => 0..0,   # GetLocL
      0x11 => 0..0,   # GetLocP
      0x12 => 1..1,   # ReadT
      0x13 => 0..0,   # GetTN
      0x14 => 1..1,   # GetTD
      0x15 => 0..0,   # SeekL
      0x16 => 0..0,   # SeekP
      0x17 => 0..0,   # SetClock
      0x18 => 0..0,   # GetClock
      0x19 => 1..16,  # Test
      0x1A => 0..0,   # GetID
      0x1B => 0..0,   # ReadS
      0x1C => 0..0,   # Reset
      0x1D => 2..2,   # GetQ
      0x1E => 0..0,   # ReadTOC
      0x1F => 6..16,  # VideoCD
    }.freeze

    attr_reader :stat
    attr_accessor :cdda_sink, :xa_adpcm_sink

    def initialize(interrupts:, disc: nil)
      @interrupts = interrupts
      @disc = disc
      @cdda_sink = nil
      @xa_adpcm_sink = nil
      reset
    end

    def disc=(disc)
      @disc = disc
      @stat = disc ? DEFAULT_STAT_DISC : DEFAULT_STAT_NO_DISC
      @disc_insert_stat_sequence = []
    end

    def disc
      @disc
    end

    def eject_disc
      @disc = nil
      @reading = false
      @cdda_playing = false
      @read_pending_seek = false
      @pause_after_first_sector = false
      @data_buffer = nil
      @data_pos = 0
      @last_sector_header_valid = false
      @last_subq_valid = false
      @stat = SF_SHELL_OPEN
      @disc_insert_stat_sequence = []
      queue_response(0, 5, [SF_ERROR])
    end

    def insert_disc(disc)
      @disc = disc
      @stat = SF_SHELL_OPEN | SF_MOTOR_ON
      @disc_insert_stat_sequence = [SF_SHELL_OPEN | SF_MOTOR_ON, SF_SHELL_OPEN, 0x00]
    end

    def reset
      @index = 0
      @parameters = []
      @response = []
      @irq_enable = 0
      @irq_flags = 0
      @pending = []          # [[delay_cycles, sequence, group, int_type, [bytes...]], ...]
      @pending_seq = 0
      @pending_group = 0
      @current_response_group = 0
      @data_buffer = nil     # binary string with current sector's user data
      @data_pos = 0
      @seek_lba = 0
      @read_lba = 0
      @mode = 0
      @speed_2x = false
      @whole_sector = false  # SetMode bit 5 — read 2340 bytes vs 2048
      @xa_enabled = false
      @xa_filter_file = 0
      @xa_filter_channel = 0
      @xa_last_samples = [0, 0, 0, 0]
      @muted = false
      @reading = false
      @sector_cycles = 0
      @sectors_since_read = 0  # how many INT1s have fired since the last ReadN
      @read_pending_seek = false
      @pause_after_first_sector = false
      @bfrd_active = false
      @want_seek = false
      @last_sector_lba = 0
      @last_sector_header = [0, 0, 0, 0]
      @last_sector_subheader = [0, 0, 0, 0]
      @last_sector_header_valid = false
      @last_subq = [0, 0, 0, 0, 0, 0, 0, 0]
      @last_subq_valid = false
      @disc_insert_stat_sequence = []
      @stat = @disc ? DEFAULT_STAT_DISC : DEFAULT_STAT_NO_DISC

      # CDDA (redbook audio) playback state. Independent of @reading so a
      # game can stream both data and audio if it ever needs to — the data
      # streamer ignores audio tracks anyway.
      @cdda_playing = false
      @cdda_lba = 0
      @cdda_cycles = 0
    end

    # --- Bus interface ------------------------------------------------------

    def read8(reg)
      case reg & 3
      when 0 then status
      when 1
        v = @response.shift || 0
        v & 0xFF
      when 2
        # Data FIFO — single byte read.
        b = (@bfrd_active && @data_buffer && @data_pos < @data_buffer.bytesize) ? @data_buffer.getbyte(@data_pos) : 0
        @data_pos += 1 if @bfrd_active && @data_buffer && @data_pos < @data_buffer.bytesize
        @bfrd_active = false if @data_buffer && @data_pos >= @data_buffer.bytesize
        b
      when 3
        case @index
        when 0, 2 then @irq_enable | 0xE0
        when 1, 3 then @irq_flags | 0xE0
        end
      end
    end

    # Pull a 32-bit word out of the data FIFO. Used by DMA channel 3 and by
    # any programmed-I/O code that reads the FIFO 32 bits at a time.
    def dma_read_word
      return 0 unless @bfrd_active && @data_buffer
      buf = @data_buffer
      sz = buf.bytesize
      b0 = (@data_pos     < sz) ? buf.getbyte(@data_pos)     : 0
      b1 = (@data_pos + 1 < sz) ? buf.getbyte(@data_pos + 1) : 0
      b2 = (@data_pos + 2 < sz) ? buf.getbyte(@data_pos + 2) : 0
      b3 = (@data_pos + 3 < sz) ? buf.getbyte(@data_pos + 3) : 0
      @data_pos += 4
      @bfrd_active = false if @data_pos >= sz
      b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    end

    def data_fifo_has_data?
      @data_buffer && @data_pos < @data_buffer.bytesize
    end

    def dma_data_ready?
      @bfrd_active && data_fifo_has_data?
    end

    def write8(reg, value)
      v = value & 0xFF
      case reg & 3
      when 0
        @index = v & 3
      when 1
        case @index
        when 0 then execute_command(v)
        # other indices: audio map / right CD audio routing — ignore
        end
      when 2
        case @index
        when 0
          @parameters.push(v) if @parameters.size < 16
        when 1
          @irq_enable = v & 0x1F
        # 2/3 = audio routing — ignore
        end
      when 3
        case @index
        when 0
          # Request register: bit 7 BFRD gates access to the data buffer.
          # OpenBIOS's `initiateDMA` writes 0 then 0x80 to "arm" the FIFO
          # before kicking off DMA — clearing the buffer on the 0-write
          # would mean DMA reads zeros. Real hardware preserves the sector
          # data across BFRD toggles; the bit just opens/closes the read
          # port. Clearing BFRD resets the FIFO read pointer.
          bfrd = (v & 0x80) != 0
          if !bfrd && @bfrd_active
            @data_pos = 0
          end
          @bfrd_active = bfrd
        when 1
          @irq_flags &= ~(v & 0x1F)
          @parameters.clear if (v & 0x40) != 0
        # 2/3 = audio volume apply — ignore
        end
      end
    end

    # Called from the main run loop. Advances any pending response delivery
    # and the sector-read state machine by `cycles` CPU cycles.
    def tick(cycles)
      # 1. Pending responses (INT3/INT5 from commands).
      if !@pending.empty? && @irq_flags == 0
        @pending.each { |entry| entry[0] -= cycles }
        ready_index = nil
        @pending.each_with_index do |entry, i|
          next if entry[0] > 0
          next if @pending.any? { |earlier| earlier[2] == entry[2] && earlier[1] < entry[1] }
          if ready_index.nil? || entry[0] < @pending[ready_index][0] ||
             (entry[0] == @pending[ready_index][0] && entry[1] < @pending[ready_index][1])
            ready_index = i
          end
        end

        if ready_index
          _, _, _, int_type, data = @pending.delete_at(ready_index)
          @response.clear
          @response.concat(data)
          @irq_flags = int_type & 0x07
          @interrupts&.request(Interrupts::IRQ_CDROM) if (@irq_enable & @irq_flags) != 0
        end
      end

      # 2. CDDA audio streaming. Independent of data reads and IRQs — audio
      # samples flow into the host audio queue regardless of what the
      # command path is doing.
      tick_cdda(cycles)

      # 3. Streaming reads (INT1 sectors).
      return unless @reading && @disc && @irq_flags == 0
      @sector_cycles -= cycles
      return if @sector_cycles > 0
      if unread_sector_blocks_stream?
        @sector_cycles = 1
        return
      end

      lba = @read_lba
      track = @disc.track_for_lba(lba)
      if track.nil?
        # DuckStation stops at lead-out/data-end without latching seek-error.
        # Seek errors belong to failed seek commands, not a streaming read
        # naturally running out of readable data.
        @reading = false
        @stat &= ~SF_READING
        @stat &= ~SF_SEEKING
        @stat &= ~SF_SEEK_ERROR
        queue_response(0, 2, [@stat])
        return
      end

      if track.audio?
        # In data-read mode, audio sectors are not delivered to the CPU.
        # DuckStation skips them and keeps the read stream alive; Rage Racer
        # depends on not poisoning later command ACKs with a stale seek-error
        # bit after crossing into audio data.
        @read_lba += 1
        @sector_cycles += next_sector_cycles
        return
      end

      whole = read_sector(lba)
      if @read_pending_seek
        @read_pending_seek = false
        @stat &= ~SF_SEEKING
        @stat |= SF_READING
      end
      if xa_audio_sector?(whole)
        process_xa_audio_sector(whole)
        @read_lba += 1
        @sector_cycles += next_sector_cycles
        return
      end

      @data_buffer = sector_payload(whole)
      @data_pos = 0
      @read_lba += 1
      @sectors_since_read += 1
      @sector_cycles += next_sector_cycles
      # INT1 immediately: sector ready.
      @response.clear
      @response.push(@stat)
      @irq_flags = 1
      @interrupts&.request(Interrupts::IRQ_CDROM) if (@irq_enable & @irq_flags) != 0

      if @pause_after_first_sector
        @pause_after_first_sector = false
        @reading = false
        @stat &= ~(SF_READING | SF_SEEKING)
        queue_response(CYCLES_PER_SECTOR_1X, 2, [@stat])
      end
    end

    # Advance CDDA playback by `cycles` CPU cycles. Reads one audio sector
    # per CYCLES_PER_SECTOR (1×/2× depending on @speed_2x) and forwards it
    # to the host audio sink as 2352 bytes of S16LE stereo PCM.
    def tick_cdda(cycles)
      return unless @cdda_playing && @disc

      period = @speed_2x ? CYCLES_PER_SECTOR_2X : CYCLES_PER_SECTOR_1X
      @cdda_cycles -= cycles
      while @cdda_cycles <= 0
        bytes = @disc.read_audio_sector(@cdda_lba)
        if bytes.nil?
          @cdda_playing = false
          @stat &= ~SF_PLAYING_CDDA
          break
        end
        update_last_subq(@cdda_lba)
        @cdda_sink&.call(bytes) unless @muted
        @cdda_lba += 1
        @cdda_cycles += period
      end
    end

    def decode_xa_adpcm_sector(whole)
      coding = @last_sector_subheader[3] || whole.getbyte(7) || 0
      stereo = (coding & 0x01) != 0
      eight_bit = (coding & 0x10) != 0
      decode_xa_adpcm_chunks(whole.byteslice(12, 18 * 128), stereo: stereo, eight_bit: eight_bit)
    end

    private

    def status
      s = @index & STAT_INDEX_MASK
      s |= STAT_PARAMETER_FIFO_EMPTY    if @parameters.empty?
      s |= STAT_PARAMETER_FIFO_NOT_FULL if @parameters.size < 16
      s |= STAT_RESPONSE_FIFO_NOT_EMPTY unless @response.empty?
      s |= STAT_DATA_FIFO_NOT_EMPTY     if @bfrd_active
      s
    end

    def queue_response(delay_cycles, int_type, data)
      @pending_seq += 1
      @pending << [
        delay_cycles.zero? ? CYCLES_PER_RESPONSE : delay_cycles,
        @pending_seq,
        @current_response_group,
        int_type,
        data.dup
      ]
    end

    def clear_sector_buffer
      @data_buffer = nil
      @data_pos = 0
      @bfrd_active = false
    end

    def clear_async_and_second_responses
      @pending.reject! { |entry| entry[3] != 3 }
    end

    def unread_sector_blocks_stream?
      return false unless @data_buffer && @data_pos < @data_buffer.bytesize
      return false unless @bfrd_active

      # In whole-sector mode games may read only a small XA/STR prefix to
      # filter unwanted sectors, or read that prefix plus the user payload and
      # leave the ECC tail unread. Only a deeper partially consumed payload
      # means the next INT1 would overwrite data the game is actively draining.
      return @data_pos > WHOLE_SECTOR_FILTER_PREFIX_BYTES && @data_pos < 2060 if @whole_sector

      true
    end

    def read_sector(lba)
      whole = @disc.read_whole_sector(lba)
      @last_sector_lba = lba
      @last_sector_header = whole.byteslice(0, 4).bytes
      @last_sector_subheader = whole.byteslice(4, 4).bytes
      @last_sector_header_valid = true
      update_last_subq(lba)
      whole
    end

    def update_last_subq(lba)
      track = @disc&.track_for_lba(lba)
      track_no = track&.number || 1
      relative_lba = track ? [lba - track.lba_start, 0].max : lba
      rm, rs, rf = Disc.lba_to_msf(relative_lba)
      am, as, af = Disc.lba_to_msf(lba)
      @last_subq = [
        Disc.to_bcd(track_no),
        0x01,
        Disc.to_bcd(rm), Disc.to_bcd(rs), Disc.to_bcd(rf),
        Disc.to_bcd(am), Disc.to_bcd(as), Disc.to_bcd(af),
      ]
      @last_subq_valid = true
    end

    def data_track_for_lba(lba)
      track = @disc&.track_for_lba(lba)
      return @disc.tracks.find { |t| t.number == 1 && t.data? } if track.nil? && @disc&.pregap_lba?(lba)
      return nil if track.nil? || track.audio?

      track
    end

    def sector_payload(whole)
      @whole_sector ? whole : whole.byteslice(12, 2048)
    end

    def xa_audio_sector?(whole)
      return false unless @xa_enabled
      return false unless whole.getbyte(3) == 0x02

      submode = whole.getbyte(6)
      realtime = (submode & 0x40) != 0
      audio = (submode & 0x04) != 0
      realtime && audio
    end

    def process_xa_audio_sector(whole)
      if (@mode & 0x08) != 0 &&
         (@last_sector_subheader[0] != @xa_filter_file || @last_sector_subheader[1] != @xa_filter_channel)
        return
      end

      decoded = decode_xa_adpcm_sector(whole)
      @xa_adpcm_sink&.call(decoded) unless @muted
    end

    def decode_xa_adpcm_chunks(chunks, stereo:, eight_bit:)
      filter_pos = [0, 60, 115, 98, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      filter_neg = [0, 0, -52, -55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      blocks = eight_bit ? 4 : 8
      output = []

      18.times do |chunk|
        chunk_offset = chunk * 128
        decoded = Array.new((eight_bit ? 112 : 224), 0)
        blocks.times do |block|
          header = chunks.getbyte(chunk_offset + 4 + block) || 0
          shift = header & 0x0F
          shift = 9 if shift > 12
          filter = (header >> 4) & 0x0F
          previous = stereo ? @xa_last_samples[(block & 1) * 2, 2] : @xa_last_samples[0, 2]

          28.times do |word|
            word_offset = chunk_offset + 16 + word * 4
            word_data =
              (chunks.getbyte(word_offset) || 0) |
              ((chunks.getbyte(word_offset + 1) || 0) << 8) |
              ((chunks.getbyte(word_offset + 2) || 0) << 16) |
              ((chunks.getbyte(word_offset + 3) || 0) << 24)
            raw = eight_bit ? ((word_data >> (block * 8)) & 0xFF) : ((word_data >> (block * 4)) & 0x0F)
            signed = sign_extend_xa_sample(raw, eight_bit)
            sample = signed >> shift
            sample += (previous[0] * filter_pos[filter]) >> 6
            sample += (previous[1] * filter_neg[filter]) >> 6
            sample = [[sample, -32_768].max, 32_767].min
            previous[1] = previous[0]
            previous[0] = sample

            index = stereo ? (block / 2) * 56 + word * 2 + (block % 2) : block * 28 + word
            decoded[index] = sample
          end

          if stereo
            @xa_last_samples[(block & 1) * 2] = previous[0]
            @xa_last_samples[(block & 1) * 2 + 1] = previous[1]
          else
            @xa_last_samples[0] = previous[0]
            @xa_last_samples[1] = previous[1]
          end
        end

        if stereo
          output.concat(decoded)
        else
          decoded.each { |sample| output << sample << sample }
        end
      end

      output.pack("s<*")
    end

    def sign_extend_xa_sample(raw, eight_bit)
      if eight_bit
        ((raw << 8) & 0xFFFF) >= 0x8000 ? ((raw << 8) & 0xFFFF) - 0x1_0000 : (raw << 8)
      else
        ((raw << 12) & 0xFFFF) >= 0x8000 ? ((raw << 12) & 0xFFFF) - 0x1_0000 : (raw << 12)
      end
    end

    def valid_bcd_byte?(value)
      (value & 0x0F) <= 9 && ((value >> 4) & 0x0F) <= 9
    end

    def execute_command(cmd)
      params = @parameters.dup
      @parameters.clear

      if ENV["PSX_TRACE_CDROM"]
        $stderr.puts format("[cdrom] cmd=%02X params=[%s] stat=%02X",
                            cmd, params.map { |p| "%02X" % p }.join(" "), @stat)
      end

      @pending_group += 1
      @current_response_group = @pending_group

      expected_params = COMMAND_PARAMETER_COUNTS[cmd]
      if expected_params && !expected_params.cover?(params.size)
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS])
        return
      end

      case cmd
      when 0x01 then cmd_getstat
      when 0x02 then cmd_setloc(params)
      when 0x03 then cmd_play(params)
      when 0x04 then cmd_forward
      when 0x05 then cmd_backward
      when 0x06 then cmd_read
      when 0x07 then cmd_motor_on
      when 0x08 then cmd_stop
      when 0x09 then cmd_pause
      when 0x0A then cmd_init
      when 0x0B then cmd_mute
      when 0x0C then cmd_demute
      when 0x0D then cmd_setfilter(params)
      when 0x0E then cmd_setmode(params)
      when 0x0F then cmd_getparam
      when 0x10 then cmd_getloc_l
      when 0x11 then cmd_getloc_p
      when 0x12 then cmd_read_t(params)
      when 0x13 then cmd_get_tn
      when 0x14 then cmd_get_td(params)
      when 0x15 then cmd_seek_l
      when 0x16 then cmd_seek_p
      when 0x19 then cmd_test(params)
      when 0x1A then cmd_get_id
      when 0x1B then cmd_read
      when 0x1E then cmd_read_toc
      else
        if ENV["PSX_TRACE_CDROM"]
          $stderr.puts format("[cdrom] UNHANDLED cmd=%02X — sending invalid-command error", cmd)
        end
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_COMMAND])
      end
    end

    # --- Commands -----------------------------------------------------------

    def cmd_getstat
      @stat = @disc_insert_stat_sequence.shift if @disc && !@disc_insert_stat_sequence.empty?
      queue_response(0, 3, [@stat])
    end

    def cmd_setloc(params)
      if params.size != 3
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS])
        return
      end

      unless valid_bcd_byte?(params[0]) &&
             valid_bcd_byte?(params[1]) && params[1] < 0x60 &&
             valid_bcd_byte?(params[2]) && params[2] < 0x75
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_ARGUMENT])
        return
      end

      m = Disc.from_bcd(params[0])
      s = Disc.from_bcd(params[1])
      f = Disc.from_bcd(params[2])
      @seek_lba = Disc.msf_to_lba(m, s, f)
      @want_seek = true
      queue_response(0, 3, [@stat])
    end

    def cmd_read
      if @disc.nil?
        queue_response(0, 3, [@stat])
        queue_response(CYCLES_PER_RESPONSE * 2, 5, [SF_ERROR | @stat, 0x80])
        return
      end

      # DuckStation ignores ReadN/ReadS if the drive is already reading the
      # same next sector. It ACKs the command, clears the pending SetLoc, and
      # leaves the sector buffers and read timing alone.
      if @reading && (!@want_seek || @seek_lba == @read_lba)
        @want_seek = false
        queue_response(0, 3, [@stat])
        return
      end

      @read_lba = @want_seek ? @seek_lba : @read_lba
      read_distance = @want_seek ? (@read_lba - @last_sector_lba).abs : 0
      @want_seek = false
      clear_async_and_second_responses
      clear_sector_buffer
      @reading = true
      @sectors_since_read = 0
      @read_pending_seek = read_distance > Disc::FRAMES_PER_SEC
      if @read_pending_seek
        @stat |= SF_SEEKING
        @stat &= ~SF_READING
      else
        @stat |= SF_READING
        @stat &= ~SF_SEEKING
      end
      # First sector lands quickly after a buffered/near read, but a far
      # SetLoc+ReadN keeps the drive visibly seeking for a short period.
      @sector_cycles = @read_pending_seek ? CYCLES_FAR_READ_SEEK : CYCLES_FIRST_SECTOR
      queue_response(0, 3, [@stat])
    end

    # CdlPlay — start streaming CDDA audio. With a parameter byte: play
    # from the start of that track number (BCD). With no parameter: play
    # from the LBA last given to SetLoc, or continue from where we left
    # off. We don't drop data reads (the @reading streamer just stops on
    # its own when the LBA hits an audio track).
    def cmd_play(params)
      if @disc.nil?
        queue_response(0, 3, [@stat])
        queue_response(CYCLES_PER_RESPONSE * 2, 5, [SF_ERROR | @stat, 0x80])
        return
      end

      if !params.empty? && params[0] != 0
        track_no = Disc.from_bcd(params[0])
        track = @disc.tracks.find { |t| t.number == track_no }
        @cdda_lba = track ? track.lba_start : @seek_lba
      else
        # No param: play from the position last given to SetLoc. Real
        # hardware doesn't care about @want_seek here — intermediate data
        # reads / pauses may have consumed it but the laser-target LBA is
        # still the seek_lba value.
        @cdda_lba = @seek_lba
        @want_seek = false
      end

      @cdda_playing = true
      @cdda_cycles = CYCLES_FIRST_SECTOR
      clear_async_and_second_responses
      clear_sector_buffer
      @stat |= SF_MOTOR_ON | SF_PLAYING_CDDA
      @stat &= ~SF_READING
      queue_response(0, 3, [@stat])
    end

    def cmd_forward
      if @disc.nil? || !@cdda_playing
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_NOT_READY])
      else
        queue_response(0, 3, [@stat])
      end
    end

    def cmd_backward
      if @disc.nil? || !@cdda_playing
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_NOT_READY])
      else
        queue_response(0, 3, [@stat])
      end
    end

    def cmd_motor_on
      @stat |= SF_MOTOR_ON
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 2, 2, [@stat])
    end

    def cmd_stop
      @reading = false
      @cdda_playing = false
      @stat &= ~(SF_READING | SF_MOTOR_ON | SF_PLAYING_CDDA)
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 2, 2, [@stat])
    end

    def cmd_pause
      was_reading = @reading
      if was_reading && @read_pending_seek
        @pause_after_first_sector = true
        queue_response(0, 3, [@stat])
        return
      end

      # If we were streaming and the BIOS hadn't yet received ANY sector
      # for this ReadN, force one delivery before stopping — the BIOS
      # commonly issues ReadN + Pause back-to-back to read a single sector.
      # Once at least one sector has been delivered we leave it alone so
      # we don't double-deliver.
      clear_async_and_second_responses
      if was_reading && @disc && @sectors_since_read.zero?
        deliver_pending_sector
      end
      @reading = false
      @cdda_playing = false
      @stat &= ~(SF_READING | SF_PLAYING_CDDA)
      queue_response(0, 3, [@stat])
      # Pause's INT2 lands after the current sector finishes. Give the BIOS
      # time to drain the data FIFO before INT2 arrives.
      delay = was_reading ? CYCLES_PER_SECTOR_1X : CYCLES_PER_RESPONSE
      queue_response(delay, 2, [@stat])
    end

    def deliver_pending_sector
      lba = @read_lba
      track = @disc.track_for_lba(lba)
      return if track.nil? || track.audio?
      whole = read_sector(lba)
      if xa_audio_sector?(whole)
        process_xa_audio_sector(whole)
        @read_lba += 1
        return
      end

      @data_buffer = sector_payload(whole)
      @data_pos = 0
      @read_lba += 1
      @sectors_since_read += 1
      queue_response(CYCLES_FIRST_SECTOR, 1, [@stat])
    end

    def next_sector_cycles
      @speed_2x ? CYCLES_PER_SECTOR_2X : CYCLES_PER_SECTOR_1X
    end

    def cmd_init
      # Init resets the drive's FIFOs, mode, and current operation, but
      # NOT the IRQ-enable mask. Real hardware preserves @irq_enable across
      # Init — a full reset(){@irq_enable=0} after BIOS init means subsequent
      # INT3/INT2 from this very Init never raise IRQ_CDROM, and the BIOS'
      # license-init poll on [0x800091C4] never sees its callback. Save and
      # restore.
      saved_enable = @irq_enable
      saved_last_sector_lba = @last_sector_lba
      saved_last_sector_header = @last_sector_header
      saved_last_sector_subheader = @last_sector_subheader
      saved_last_sector_header_valid = @last_sector_header_valid
      saved_last_subq = @last_subq
      saved_last_subq_valid = @last_subq_valid
      reset
      @irq_enable = saved_enable
      @last_sector_lba = saved_last_sector_lba
      @last_sector_header = saved_last_sector_header
      @last_sector_subheader = saved_last_sector_subheader
      @last_sector_header_valid = saved_last_sector_header_valid
      @last_subq = saved_last_subq
      @last_subq_valid = saved_last_subq_valid
      @stat = @disc ? DEFAULT_STAT_DISC : DEFAULT_STAT_NO_DISC
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 4, 2, [@stat])
    end

    def cmd_mute
      @muted = true
      queue_response(0, 3, [@stat])
    end

    def cmd_demute
      @muted = false
      queue_response(0, 3, [@stat])
    end

    def cmd_setfilter(params)
      if params.size != 2
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS])
        return
      end

      @xa_filter_file = params[0] & 0xFF
      @xa_filter_channel = params[1] & 0xFF
      queue_response(0, 3, [@stat])
    end

    def cmd_setmode(params)
      if params.size != 1
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS])
        return
      end

      @mode = params[0] & 0xFF
      @speed_2x = (@mode & 0x80) != 0
      @whole_sector = (@mode & 0x20) != 0
      @xa_enabled = (@mode & 0x40) != 0
      queue_response(0, 3, [@stat])
    end

    def cmd_getparam
      queue_response(0, 3, [@stat, @mode, 0x00, @xa_filter_file, @xa_filter_channel])
    end

    def cmd_getloc_l
      # nocash: GetlocL returns 8 bytes: amm, ass, asect, mode, file, channel, sm, ci
      if @last_sector_header_valid
        queue_response(0, 3, @last_sector_header + @last_sector_subheader)
      else
        queue_response(0, 5, [SF_ERROR | @stat, 0x80])
      end
    end

    def cmd_getloc_p
      update_last_subq(@read_lba) if @disc && !@last_subq_valid && data_track_for_lba(@read_lba)
      if @disc && @last_subq_valid
        queue_response(0, 3, @last_subq)
      else
        queue_response(0, 5, [SF_ERROR | @stat, 0x80])
      end
    end

    def cmd_read_t(params)
      if @disc.nil? || @reading || @cdda_playing
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_NOT_READY])
      elsif params[0].zero?
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_ARGUMENT])
      else
        @stat |= SF_MOTOR_ON
        queue_response(0, 3, [@stat])
        if params[0] == 0x01
          queue_response(CYCLES_PER_RESPONSE * 8, 2, [@stat])
        else
          queue_response(CYCLES_PER_RESPONSE * 8, 5, [SF_SEEK_ERROR | @stat, ERROR_REASON_INVALID_COMMAND])
        end
      end
    end

    def cmd_get_tn
      unless @disc
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_NOT_READY])
        return
      end

      first = 1
      last = @disc.track_count
      queue_response(0, 3, [@stat, Disc.to_bcd(first), Disc.to_bcd(last)])
    end

    def cmd_get_td(params)
      if params.size != 1
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS])
        return
      end

      unless @disc
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_NOT_READY])
        return
      end

      unless valid_bcd_byte?(params[0])
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_ARGUMENT])
        return
      end

      track_no = Disc.from_bcd(params[0])
      if track_no == 0
        # Track 0 means "end of disc"
        lba_end = @disc.total_sectors
        m, s, _ = Disc.lba_to_msf(lba_end)
        queue_response(0, 3, [@stat, Disc.to_bcd(m), Disc.to_bcd(s)])
      else
        if track_no > @disc.track_count
          queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_ARGUMENT])
          return
        end

        track = @disc.tracks.find { |t| t.number == track_no }
        if track
          m, s, _ = Disc.lba_to_msf(track.lba_start)
          queue_response(0, 3, [@stat, Disc.to_bcd(m), Disc.to_bcd(s)])
        else
          queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_ARGUMENT])
        end
      end
    end

    def cmd_seek_l
      target_lba = @want_seek ? @seek_lba : @read_lba
      @want_seek = false
      @read_lba = target_lba
      @stat |= SF_SEEKING
      queue_response(0, 3, [@stat])
      clear_async_and_second_responses
      clear_sector_buffer

      track = @disc&.track_for_lba(target_lba)
      if @disc.nil? || (data_track_for_lba(target_lba).nil? && !(track&.audio?))
        @stat &= ~SF_SEEKING
        @stat |= SF_SEEK_ERROR
        @last_sector_header_valid = false
        @last_subq_valid = false
        queue_response(CYCLES_PER_RESPONSE * 4, 5, [@stat, 0x04])
        return
      end

      if track&.audio?
        update_last_subq(target_lba)
        @last_sector_header_valid = false
        @stat &= ~(SF_SEEKING | SF_SEEK_ERROR)
        queue_response(CYCLES_PER_RESPONSE * 4, 2, [@stat])
        return
      end

      read_sector(target_lba)
      @stat &= ~(SF_SEEKING | SF_SEEK_ERROR)
      queue_response(CYCLES_PER_RESPONSE * 4, 2, [@stat])
    end

    def cmd_seek_p
      cmd_seek_l
    end

    def cmd_test(params)
      sub = params[0]
      case sub
      when 0x04
        @stat |= SF_MOTOR_ON
        queue_response(0, 3, [@stat])
      when 0x05
        queue_response(0, 3, [0x00, 0x00])
      when 0x20
        # Get BIOS date/version. SCPH1001-ish values.
        queue_response(0, 3, [0x94, 0x09, 0x19, 0xC0])
      when 0x60
        if params.size < 3
          queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS])
        else
          queue_response(0, 3, [0x00])
        end
      else
        queue_response(0, 5, [SF_ERROR | @stat, ERROR_REASON_INVALID_COMMAND])
      end
    end

    def cmd_get_id
      if @disc.nil?
        queue_response(0, 3, [@stat])
        queue_response(CYCLES_PER_RESPONSE * 2, 5, [0x11, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
      else
        # Licensed mode-2 disc response per nocash:
        # INT3(stat); INT2(stat, 00h, 20h, 00h, "SCE?")
        queue_response(0, 3, [@stat])
        queue_response(CYCLES_PER_RESPONSE * 2, 2,
                       [0x02, 0x00, 0x20, 0x00] + get_id_region_string.bytes)
      end
    end

    def get_id_region_string
      case @disc.respond_to?(:region_code) ? @disc.region_code : :ntsc_u
      when :ntsc_j then "SCEI"
      when :pal then "SCEE"
      else "SCEA"
      end
    end

    def cmd_read_toc
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 8, 2, [@stat])
    end
  end
end
