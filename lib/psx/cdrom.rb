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

    # Timing constants (in CPU cycles).
    CYCLES_PER_SECTOR_1X = 33_868_800 / 75
    CYCLES_PER_SECTOR_2X = CYCLES_PER_SECTOR_1X / 2
    CYCLES_PER_RESPONSE  = 20_000
    # First sector after a seek arrives quickly — the drive pre-buffers
    # during SeekL, so when ReadN starts streaming the first INT1 lands
    # almost immediately. Subsequent sectors space out at the real cadence.
    CYCLES_FIRST_SECTOR  = 30_000

    DEFAULT_STAT_DISC    = SF_MOTOR_ON
    DEFAULT_STAT_NO_DISC = SF_SHELL_OPEN

    attr_reader :stat

    def initialize(interrupts:, disc: nil)
      @interrupts = interrupts
      @disc = disc
      reset
    end

    def disc=(disc)
      @disc = disc
      @stat = disc ? DEFAULT_STAT_DISC : DEFAULT_STAT_NO_DISC
    end

    def disc
      @disc
    end

    def reset
      @index = 0
      @parameters = []
      @response = []
      @irq_enable = 0
      @irq_flags = 0
      @pending = []          # [[delay_cycles, int_type, [bytes...]], ...]
      @data_buffer = nil     # binary string with current sector's user data
      @data_pos = 0
      @seek_lba = 0
      @read_lba = 0
      @speed_2x = false
      @whole_sector = false  # SetMode bit 5 — read 2340 bytes vs 2048
      @reading = false
      @sector_cycles = 0
      @want_seek = false
      @stat = @disc ? DEFAULT_STAT_DISC : DEFAULT_STAT_NO_DISC
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
        b = (@data_buffer && @data_pos < @data_buffer.bytesize) ? @data_buffer.getbyte(@data_pos) : 0
        @data_pos += 1 if @data_buffer && @data_pos < @data_buffer.bytesize
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
      return 0 unless @data_buffer
      buf = @data_buffer
      sz = buf.bytesize
      b0 = (@data_pos     < sz) ? buf.getbyte(@data_pos)     : 0
      b1 = (@data_pos + 1 < sz) ? buf.getbyte(@data_pos + 1) : 0
      b2 = (@data_pos + 2 < sz) ? buf.getbyte(@data_pos + 2) : 0
      b3 = (@data_pos + 3 < sz) ? buf.getbyte(@data_pos + 3) : 0
      @data_pos += 4
      b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    end

    def data_fifo_has_data?
      @data_buffer && @data_pos < @data_buffer.bytesize
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
          # Request register: bit 7 BFRD enables data buffer read. When the
          # BIOS sets BFRD after a sector arrives, the data buffer becomes
          # available; when it clears it, the buffer empties.
          bfrd = (v & 0x80) != 0
          if bfrd
            @data_pos = 0 unless @data_buffer
          else
            @data_buffer = nil
            @data_pos = 0
          end
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
        @pending[0][0] -= cycles
        if @pending[0][0] <= 0
          _, int_type, data = @pending.shift
          @response.clear
          @response.concat(data)
          @irq_flags = int_type & 0x07
          @interrupts&.request(Interrupts::IRQ_CDROM) if (@irq_enable & @irq_flags) != 0
        end
      end

      # 2. Streaming reads (INT1 sectors).
      return unless @reading && @disc && @irq_flags == 0
      @sector_cycles -= cycles
      return if @sector_cycles > 0

      lba = @read_lba
      track = @disc.track_for_lba(lba)
      if track.nil? || track.audio?
        # Out of range or hit an audio track — terminate the stream with
        # an INT5 error.
        @reading = false
        @stat &= ~SF_READING
        @stat |= SF_SEEK_ERROR
        queue_response(0, 5, [@stat, 0x04]) # 0x04 = seek error code
        return
      end

      data = @disc.read_data(lba)
      @data_buffer = data
      @data_pos = 0
      @read_lba += 1
      @sector_cycles += @speed_2x ? CYCLES_PER_SECTOR_2X : CYCLES_PER_SECTOR_1X
      # INT1 immediately: sector ready.
      @response.clear
      @response.push(@stat)
      @irq_flags = 1
      @interrupts&.request(Interrupts::IRQ_CDROM) if (@irq_enable & @irq_flags) != 0
    end

    private

    def status
      s = @index & STAT_INDEX_MASK
      s |= STAT_PARAMETER_FIFO_EMPTY    if @parameters.empty?
      s |= STAT_PARAMETER_FIFO_NOT_FULL if @parameters.size < 16
      s |= STAT_RESPONSE_FIFO_NOT_EMPTY unless @response.empty?
      s |= STAT_DATA_FIFO_NOT_EMPTY     if data_fifo_has_data?
      s
    end

    def queue_response(delay_cycles, int_type, data)
      @pending << [delay_cycles.zero? ? CYCLES_PER_RESPONSE : delay_cycles, int_type, data.dup]
    end

    def execute_command(cmd)
      params = @parameters.dup
      @parameters.clear

      case cmd
      when 0x01 then cmd_getstat
      when 0x02 then cmd_setloc(params)
      when 0x06 then cmd_read
      when 0x07 then cmd_motor_on
      when 0x08 then cmd_stop
      when 0x09 then cmd_pause
      when 0x0A then cmd_init
      when 0x0B then cmd_mute
      when 0x0C then cmd_demute
      when 0x0D then cmd_setfilter
      when 0x0E then cmd_setmode(params)
      when 0x0F then cmd_getparam
      when 0x10 then cmd_getloc_l
      when 0x11 then cmd_getloc_p
      when 0x13 then cmd_get_tn
      when 0x14 then cmd_get_td(params)
      when 0x15 then cmd_seek_l
      when 0x16 then cmd_seek_p
      when 0x19 then cmd_test(params)
      when 0x1A then cmd_get_id
      when 0x1B then cmd_read
      when 0x1E then cmd_read_toc
      else
        queue_response(0, 3, [@stat])  # default ack to keep BIOS moving
      end
    end

    # --- Commands -----------------------------------------------------------

    def cmd_getstat
      queue_response(0, 3, [@stat])
    end

    def cmd_setloc(params)
      raise "Setloc needs 3 BCD params" if params.size < 3
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
      @read_lba = @want_seek ? @seek_lba : @read_lba
      @want_seek = false
      @reading = true
      @stat |= SF_READING
      @stat &= ~SF_SEEKING
      # First sector lands quickly — see CYCLES_FIRST_SECTOR. After it the
      # cadence falls back to the full 1×/2× period.
      @sector_cycles = CYCLES_FIRST_SECTOR
      queue_response(0, 3, [@stat])
    end

    def cmd_motor_on
      @stat |= SF_MOTOR_ON
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 2, 2, [@stat])
    end

    def cmd_stop
      @reading = false
      @stat &= ~(SF_READING | SF_MOTOR_ON)
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 2, 2, [@stat])
    end

    def cmd_pause
      was_reading = @reading
      @reading = false
      @stat &= ~SF_READING
      queue_response(0, 3, [@stat])
      # Real Pause has a longer second-response delay than most other
      # commands (the drive needs to finish the current sector). Use the
      # full 1× period so any in-flight INT1 lands before the INT2.
      delay = was_reading ? CYCLES_PER_SECTOR_1X : CYCLES_PER_RESPONSE
      queue_response(delay, 2, [@stat])
    end

    def cmd_init
      reset
      @stat = @disc ? DEFAULT_STAT_DISC : DEFAULT_STAT_NO_DISC
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 4, 2, [@stat])
    end

    def cmd_mute
      queue_response(0, 3, [@stat])
    end

    def cmd_demute
      queue_response(0, 3, [@stat])
    end

    def cmd_setfilter
      queue_response(0, 3, [@stat])
    end

    def cmd_setmode(params)
      raise "Setmode needs 1 param" if params.empty?
      mode = params[0]
      @speed_2x = (mode & 0x80) != 0
      @whole_sector = (mode & 0x20) != 0
      queue_response(0, 3, [@stat])
    end

    def cmd_getparam
      queue_response(0, 3, [@stat, 0x00, 0x00, 0x00])
    end

    def cmd_getloc_l
      m, s, f = Disc.lba_to_msf(@read_lba)
      # nocash: GetlocL returns 8 bytes: amm, ass, asect, mode, file, channel, sm, ci
      queue_response(0, 3, [Disc.to_bcd(m), Disc.to_bcd(s), Disc.to_bcd(f), 0x02, 0, 0, 0, 0])
    end

    def cmd_getloc_p
      m, s, f = Disc.lba_to_msf(@read_lba)
      track = @disc&.track_for_lba(@read_lba)
      track_no = track&.number || 1
      # Track-relative MSF
      tm, ts, tf = Disc.lba_to_msf((@read_lba - (track&.lba_start || 0)).clamp(0, @read_lba))
      queue_response(0, 3, [
        Disc.to_bcd(track_no),
        0x01,                      # index
        Disc.to_bcd(tm), Disc.to_bcd(ts), Disc.to_bcd(tf),
        Disc.to_bcd(m),  Disc.to_bcd(s),  Disc.to_bcd(f)
      ])
    end

    def cmd_get_tn
      first = 1
      last = @disc ? @disc.track_count : 1
      queue_response(0, 3, [@stat, Disc.to_bcd(first), Disc.to_bcd(last)])
    end

    def cmd_get_td(params)
      raise "GetTD needs 1 BCD param" if params.empty?
      track_no = Disc.from_bcd(params[0])
      if track_no == 0
        # Track 0 means "end of disc"
        lba_end = @disc ? @disc.total_sectors : 0
        m, s, _ = Disc.lba_to_msf(lba_end)
        queue_response(0, 3, [@stat, Disc.to_bcd(m), Disc.to_bcd(s)])
      else
        track = @disc&.tracks&.find { |t| t.number == track_no }
        if track
          m, s, _ = Disc.lba_to_msf(track.lba_start)
          queue_response(0, 3, [@stat, Disc.to_bcd(m), Disc.to_bcd(s)])
        else
          queue_response(0, 3, [@stat, 0x00, 0x00])
        end
      end
    end

    def cmd_seek_l
      if @want_seek
        @read_lba = @seek_lba
        @want_seek = false
      end
      @stat |= SF_SEEKING
      queue_response(0, 3, [@stat])
      @stat &= ~SF_SEEKING
      queue_response(CYCLES_PER_RESPONSE * 4, 2, [@stat])
    end

    def cmd_seek_p
      cmd_seek_l
    end

    def cmd_test(params)
      sub = params[0]
      case sub
      when 0x20
        # Get BIOS date/version. SCPH1001-ish values.
        queue_response(0, 3, [0x94, 0x09, 0x19, 0xC0])
      else
        queue_response(0, 3, [@stat])
      end
    end

    def cmd_get_id
      if @disc.nil?
        queue_response(0, 3, [@stat])
        queue_response(CYCLES_PER_RESPONSE * 2, 5, [0x11, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
      else
        # Licensed mode-2 disc response per nocash:
        # INT3(stat); INT2(stat, 00h, 20h, 00h, "SCEA")
        queue_response(0, 3, [@stat])
        queue_response(CYCLES_PER_RESPONSE * 2, 2,
                       [0x02, 0x00, 0x20, 0x00, 0x53, 0x43, 0x45, 0x41])
      end
    end

    def cmd_read_toc
      queue_response(0, 3, [@stat])
      queue_response(CYCLES_PER_RESPONSE * 8, 2, [@stat])
    end
  end
end
