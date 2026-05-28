# frozen_string_literal: true

module PSX
  # SPU — partial register/DMA model. It satisfies programs that probe
  # SPUCNT/SPUSTAT, round-trips data through SPU RAM via FIFO and DMA
  # channel 4, tracks voice key on/off state, and produces basic decoded
  # ADPCM PCM output.
  class SPU
    RAM_SIZE = 512 * 1024

    # IO offsets relative to 0x1F801000
    SPU_TRANSFER_ADDR = 0xDA6
    SPU_FIFO          = 0xDA8
    SPUCNT            = 0xDAA
    SPUDTC            = 0xDAC
    SPUSTAT           = 0xDAE
    KEY_ON_LOW        = 0xD88
    KEY_ON_HIGH       = 0xD8A
    KEY_OFF_LOW       = 0xD8C
    KEY_OFF_HIGH      = 0xD8E
    ENDX_LOW          = 0xD9C
    ENDX_HIGH         = 0xD9E
    SPU_IRQ_ADDR      = 0xDA4
    MAIN_VOL_LEFT     = 0xD80
    MAIN_VOL_RIGHT    = 0xD82
    REVERB_VOL_LEFT   = 0xD84
    REVERB_VOL_RIGHT  = 0xD86
    PITCH_MOD_LOW     = 0xD90
    PITCH_MOD_HIGH    = 0xD92
    NOISE_MODE_LOW    = 0xD94
    NOISE_MODE_HIGH   = 0xD96
    REVERB_ON_LOW     = 0xD98
    REVERB_ON_HIGH    = 0xD9A
    REVERB_BASE       = 0xDA2
    CD_AUDIO_VOL_LEFT = 0xDB0
    CD_AUDIO_VOL_RIGHT = 0xDB2
    EXTERNAL_VOL_LEFT = 0xDB4
    EXTERNAL_VOL_RIGHT = 0xDB6
    CURRENT_MAIN_VOL_LEFT = 0xDB8
    CURRENT_MAIN_VOL_RIGHT = 0xDBA
    CURRENT_VOICE_VOL_BASE = 0xE00
    REVERB_REG_BASE   = 0xDC0
    REVERB_REG_END    = 0xE00
    CYCLES_PER_SAMPLE = 768

    # SPUCNT bits 4-5 = transfer mode
    MODE_STOP   = 0
    MODE_MANUAL = 1
    MODE_DMA_W  = 2
    MODE_DMA_R  = 3
    SPUSTAT_DMA_REQUEST       = 1 << 7
    SPUSTAT_DMA_READ_REQUEST  = 1 << 8
    SPUSTAT_DMA_WRITE_REQUEST = 1 << 9
    SPUSTAT_DMA_BITS = SPUSTAT_DMA_REQUEST | SPUSTAT_DMA_READ_REQUEST | SPUSTAT_DMA_WRITE_REQUEST
    VoiceState = Struct.new(
      :current_address,
      :repeat_address,
      :adsr_volume,
      :adsr_phase,
      :adsr_target,
      :adsr_envelope,
      :last_samples,
      :decoded_samples,
      :current_block_flags,
      :sample_index,
      :sample_counter,
      :last_volume,
      :is_first_block,
      :ignore_loop_address,
      :left_volume,
      :right_volume,
      :left_volume_envelope,
      :right_volume_envelope,
      :left_volume_sweep_active,
      :right_volume_sweep_active,
      keyword_init: true
    )

    attr_accessor :pcm_sink

    def initialize(interrupts: nil)
      @interrupts = interrupts
      @pcm_sink = nil
      @ram = ("\x00" * RAM_SIZE).b
      @irq_addr = 0
      @transfer_addr = 0   # latched value (byte address)
      @current_addr  = 0   # advances during transfers
      @cnt = 0
      @stat = 0
      @dtc = 0
      @fifo = []
      @key_on = 0
      @key_off = 0
      @endx = 0
      @voice_active = 0
      @main_left_volume = 0
      @main_right_volume = 0
      @main_left_current_volume = 0
      @main_right_current_volume = 0
      @main_left_volume_envelope = reset_volume_envelope(0, 0x7F, false, false, false)
      @main_right_volume_envelope = reset_volume_envelope(0, 0x7F, false, false, false)
      @main_left_volume_sweep_active = false
      @main_right_volume_sweep_active = false
      @pitch_modulation_enable = 0
      @noise_mode_enable = 0
      @noise_count = 0
      @noise_level = 1
      @reverb_on_enable = 0
      @reverb_left_volume = 0
      @reverb_right_volume = 0
      @reverb_base = 0
      @reverb_registers = Array.new(32, 0)
      @cd_audio_left_volume = 0
      @cd_audio_right_volume = 0
      @external_left_volume = 0
      @external_right_volume = 0
      @cd_audio_fifo = []
      @voices = Array.new(24) do
        VoiceState.new(
          current_address: 0,
          repeat_address: 0,
          adsr_volume: 0,
          adsr_phase: :off,
          adsr_target: 0,
          adsr_envelope: reset_volume_envelope(0, 0, false, false, false),
          last_samples: [0, 0],
          decoded_samples: [],
          current_block_flags: 0,
          sample_index: 0,
          sample_counter: 0,
          last_volume: 0,
          is_first_block: false,
          ignore_loop_address: false,
          left_volume: 0,
          right_volume: 0,
          left_volume_envelope: reset_volume_envelope(0, 0x7F, false, false, false),
          right_volume_envelope: reset_volume_envelope(0, 0x7F, false, false, false),
          left_volume_sweep_active: false,
          right_volume_sweep_active: false
        )
      end
      # 1KB shadow of the SPU register window (0x1F801C00..0x1F801FFF).
      # Real hardware preserves register-write values across reads (most
      # voice/reverb regs aren't write-only); ps1-tests cpu/code-in-io
      # writes a `jr ra` instruction into voice 0's volume registers and
      # expects to read it back via instruction fetch. Specific registers
      # below override this with their own semantics.
      @regs = ("\x00" * 0x400).b
    end

    def read16(offset)
      case offset
      when KEY_ON_LOW        then @key_on & 0xFFFF
      when KEY_ON_HIGH       then (@key_on >> 16) & 0xFFFF
      when KEY_OFF_LOW       then @key_off & 0xFFFF
      when KEY_OFF_HIGH      then (@key_off >> 16) & 0xFFFF
      when ENDX_LOW          then @endx & 0xFFFF
      when ENDX_HIGH         then (@endx >> 16) & 0xFFFF
      when SPU_IRQ_ADDR      then @irq_addr
      when MAIN_VOL_LEFT     then @main_left_volume
      when MAIN_VOL_RIGHT    then @main_right_volume
      when PITCH_MOD_LOW     then @pitch_modulation_enable & 0xFFFF
      when PITCH_MOD_HIGH    then (@pitch_modulation_enable >> 16) & 0xFFFF
      when NOISE_MODE_LOW    then @noise_mode_enable & 0xFFFF
      when NOISE_MODE_HIGH   then (@noise_mode_enable >> 16) & 0xFFFF
      when REVERB_ON_LOW     then @reverb_on_enable & 0xFFFF
      when REVERB_ON_HIGH    then (@reverb_on_enable >> 16) & 0xFFFF
      when REVERB_VOL_LEFT   then @reverb_left_volume
      when REVERB_VOL_RIGHT  then @reverb_right_volume
      when REVERB_BASE       then @reverb_base
      when SPU_TRANSFER_ADDR then @transfer_addr >> 3
      when SPU_FIFO          then 0xFFFF
      when SPUCNT            then @cnt
      when SPUDTC            then @dtc
      when SPUSTAT           then @stat
      when CD_AUDIO_VOL_LEFT then @cd_audio_left_volume
      when CD_AUDIO_VOL_RIGHT then @cd_audio_right_volume
      when EXTERNAL_VOL_LEFT then @external_left_volume
      when EXTERNAL_VOL_RIGHT then @external_right_volume
      when CURRENT_MAIN_VOL_LEFT then @main_left_current_volume & 0xFFFF
      when CURRENT_MAIN_VOL_RIGHT then @main_right_current_volume & 0xFFFF
      else
        reverb_register = read_reverb_register(offset)
        return reverb_register unless reverb_register.nil?

        current_voice_volume = read_current_voice_volume(offset)
        return current_voice_volume unless current_voice_volume.nil?

        idx = offset - 0xC00
        return 0 unless idx >= 0 && idx < 0x400 - 1
        @regs.getbyte(idx) | (@regs.getbyte(idx + 1) << 8)
      end
    end

    def write16(offset, value)
      v = value & 0xFFFF
      idx = offset - 0xC00
      if idx >= 0 && idx < 0x400 - 1
        @regs.setbyte(idx, v & 0xFF)
        @regs.setbyte(idx + 1, (v >> 8) & 0xFF)
      end
      case offset
      when KEY_ON_LOW
        @key_on = (@key_on & 0xFFFF_0000) | v
        key_on(v)
      when KEY_ON_HIGH
        @key_on = (@key_on & 0x0000_FFFF) | (v << 16)
        key_on(v << 16)
      when KEY_OFF_LOW
        @key_off = (@key_off & 0xFFFF_0000) | v
        key_off(v)
      when KEY_OFF_HIGH
        @key_off = (@key_off & 0x0000_FFFF) | (v << 16)
        key_off(v << 16)
      when SPU_IRQ_ADDR
        @irq_addr = v
        trigger_ram_irq if irq_enabled? && irq_transfer_match?(@current_addr)
      when SPU_TRANSFER_ADDR
        @transfer_addr = (v * 8) & (RAM_SIZE - 1)
        @current_addr = @transfer_addr
        trigger_ram_irq if irq_enabled? && irq_transfer_match?(@current_addr)
      when SPU_FIFO
        if mode == MODE_MANUAL
          # In ManualWrite mode each FIFO write streams straight to SPU RAM,
          # advancing the transfer pointer.
          write_word_to_ram(v)
        else
          # In other modes the data is buffered; on the transition to
          # ManualWrite the buffer drains in order.
          @fifo << v
          update_dma_request_flags
        end
      when SPUCNT
        prev_mode = mode
        was_enabled = (@cnt & (1 << 15)) != 0
        @cnt = v
        if was_enabled && (@cnt & (1 << 15)).zero?
          force_all_voices_off
        end
        # SPUSTAT bits 0-5 mirror SPUCNT bits 0-5 (real hardware applies a
        # short delay; we apply immediately, which is enough for software
        # that polls in a loop).
        @stat = (@stat & ~0x3F) | (@cnt & 0x3F)
        unless irq_enabled?
          @stat &= ~(1 << 6)
        else
          trigger_ram_irq if irq_transfer_match?(@current_addr)
        end
        drain_fifo if mode == MODE_MANUAL && prev_mode != MODE_MANUAL
        update_dma_request_flags
      when SPUDTC
        @dtc = v
      when MAIN_VOL_LEFT
        @main_left_volume = v
        @main_left_current_volume, @main_left_volume_envelope, @main_left_volume_sweep_active =
          reset_volume_sweep(v, @main_left_current_volume)
      when MAIN_VOL_RIGHT
        @main_right_volume = v
        @main_right_current_volume, @main_right_volume_envelope, @main_right_volume_sweep_active =
          reset_volume_sweep(v, @main_right_current_volume)
      when PITCH_MOD_LOW
        @pitch_modulation_enable = (@pitch_modulation_enable & 0xFFFF_0000) | v
      when PITCH_MOD_HIGH
        @pitch_modulation_enable = (@pitch_modulation_enable & 0x0000_FFFF) | (v << 16)
      when NOISE_MODE_LOW
        @noise_mode_enable = (@noise_mode_enable & 0xFFFF_0000) | v
      when NOISE_MODE_HIGH
        @noise_mode_enable = (@noise_mode_enable & 0x0000_FFFF) | (v << 16)
      when REVERB_ON_LOW
        @reverb_on_enable = (@reverb_on_enable & 0xFFFF_0000) | v
      when REVERB_ON_HIGH
        @reverb_on_enable = (@reverb_on_enable & 0x0000_FFFF) | (v << 16)
      when REVERB_VOL_LEFT
        @reverb_left_volume = v
      when REVERB_VOL_RIGHT
        @reverb_right_volume = v
      when REVERB_BASE
        @reverb_base = v
      when CD_AUDIO_VOL_LEFT
        @cd_audio_left_volume = v
      when CD_AUDIO_VOL_RIGHT
        @cd_audio_right_volume = v
      when EXTERNAL_VOL_LEFT
        @external_left_volume = v
      when EXTERNAL_VOL_RIGHT
        @external_right_volume = v
      when CURRENT_MAIN_VOL_LEFT
        @main_left_current_volume = signed16(v)
      when CURRENT_MAIN_VOL_RIGHT
        @main_right_current_volume = signed16(v)
      else
        return if write_reverb_register(offset, v)

        handle_voice_register_write(offset, v)
      end
    end

    # Used by DMA channel 4. Returns one 32-bit word read from SPU RAM at
    # the current transfer pointer, advancing it.
    def dma_read_word
      word = 0
      4.times do |i|
        trigger_ram_irq if irq_enabled? && irq_transfer_match?(@current_addr)
        word |= @ram.getbyte(@current_addr) << (i * 8)
        @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
      end
      word
    end

    def dma_write_word(word)
      4.times do |i|
        trigger_ram_irq if irq_enabled? && irq_transfer_match?(@current_addr)
        @ram.setbyte(@current_addr, (word >> (i * 8)) & 0xFF)
        @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
      end
    end

    def read_adpcm_block(address)
      ram_address = (address * 8) & (RAM_SIZE - 1)
      trigger_ram_irq if irq_enabled? && (irq_transfer_match?(ram_address) || irq_transfer_match?(ram_address + 8))
      bytes = 16.times.map { |i| @ram.getbyte((ram_address + i) & (RAM_SIZE - 1)) }
      {
        shift_filter: bytes[0],
        flags: bytes[1],
        data: bytes[2, 14],
      }
    end

    def decode_adpcm_block(block, last_samples = [0, 0])
      filter_pos = [0, 60, 115, 98, 122, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      filter_neg = [0, 0, -52, -55, -60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      shift = block[:shift_filter] & 0x0F
      shift = 9 if shift > 12
      filter = (block[:shift_filter] >> 4) & 0x0F
      previous = last_samples.dup
      samples = []

      28.times do |i|
        byte = block[:data][i / 2]
        nibble = i.even? ? (byte & 0x0F) : ((byte >> 4) & 0x0F)
        signed_nibble = nibble >= 8 ? nibble - 16 : nibble
        sample = (signed_nibble << 12) >> shift
        sample += (previous[0] * filter_pos[filter]) >> 6
        sample += (previous[1] * filter_neg[filter]) >> 6
        sample = [[sample, -32_768].max, 32_767].min
        previous[1] = previous[0]
        previous[0] = sample
        samples << sample
      end

      [samples, previous]
    end

    def tick(cycles)
      @sample_cycle_accumulator ||= 0
      @sample_cycle_accumulator += cycles
      while @sample_cycle_accumulator >= CYCLES_PER_SAMPLE
        @sample_cycle_accumulator -= CYCLES_PER_SAMPLE
        tick_sample
      end
    end

    def queue_cd_audio(bytes)
      @cd_audio_fifo.concat(bytes.unpack("s<*"))
    end

    private

    def mode
      (@cnt >> 4) & 0x3
    end

    def irq_enabled?
      (@cnt & (1 << 6)) != 0 && (@stat & (1 << 6)).zero?
    end

    def irq_transfer_match?(addr)
      ((@irq_addr * 8) & (RAM_SIZE - 1)) == (addr & (RAM_SIZE - 1))
    end

    def trigger_ram_irq
      @stat |= (1 << 6)
      @interrupts&.request(Interrupts::IRQ_SPU)
    end

    def key_on(mask)
      mask &= 0x00FF_FFFF
      @voice_active |= mask
      @endx &= ~mask
      24.times do |voice|
        next if (mask & (1 << voice)).zero?

        adsr_offset = 0xC00 + voice * 0x10 + 0x0C
        @regs.setbyte(adsr_offset - 0xC00, 0)
        @regs.setbyte(adsr_offset - 0xC00 + 1, 0)
        start_address = read16(0xC00 + voice * 0x10 + 0x06) & ~1
        @voices[voice].current_address = start_address
        @voices[voice].repeat_address = read16(0xC00 + voice * 0x10 + 0x0E) & ~1
        @voices[voice].adsr_volume = 0
        @voices[voice].adsr_phase = :attack
        @voices[voice].last_samples = [0, 0]
        @voices[voice].sample_index = 0
        @voices[voice].sample_counter = 0
        @voices[voice].is_first_block = true
        @voices[voice].ignore_loop_address = false
        update_adsr_envelope(voice)
        decode_voice_block(voice)
      end
    end

    def key_off(mask)
      mask &= 0x00FF_FFFF
      24.times do |voice|
        next if (mask & (1 << voice)).zero?

        @voices[voice].adsr_phase = :release
        update_adsr_envelope(voice)
      end
    end

    def force_all_voices_off
      @voice_active = 0
      24.times do |voice|
        @voices[voice].adsr_phase = :off
        @voices[voice].adsr_volume = 0
        adsr_offset = 0xC00 + voice * 0x10 + 0x0C
        @regs.setbyte(adsr_offset - 0xC00, 0)
        @regs.setbyte(adsr_offset - 0xC00 + 1, 0)
      end
    end

    def handle_voice_register_write(offset, value)
      voice_offset = offset - 0xC00
      return unless voice_offset >= 0 && voice_offset < 24 * 0x10

      voice_index = voice_offset / 0x10
      reg = voice_offset & 0x0F
      voice = @voices[voice_index]
      case reg
      when 0x00
        voice.left_volume, voice.left_volume_envelope, voice.left_volume_sweep_active =
          reset_volume_sweep(value, voice.left_volume)
      when 0x02
        voice.right_volume, voice.right_volume_envelope, voice.right_volume_sweep_active =
          reset_volume_sweep(value, voice.right_volume)
      when 0x08, 0x0A
        update_adsr_envelope(voice_index) unless voice.adsr_phase == :off
      when 0x0C
        voice.adsr_volume = signed16(value)
      when 0x0E
        voice.repeat_address = value & ~1
        ignore_loop_address = voice.adsr_phase == :off || !voice.is_first_block
        voice.ignore_loop_address ||= ignore_loop_address
      end
    end

    def write_word_to_ram(v)
      trigger_ram_irq if irq_enabled? && irq_transfer_match?(@current_addr)
      @ram.setbyte(@current_addr, v & 0xFF)
      @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
      trigger_ram_irq if irq_enabled? && irq_transfer_match?(@current_addr)
      @ram.setbyte(@current_addr, (v >> 8) & 0xFF)
      @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
    end

    def drain_fifo
      until @fifo.empty?
        write_word_to_ram(@fifo.shift)
      end
      update_dma_request_flags
    end

    def update_dma_request_flags
      @stat &= ~SPUSTAT_DMA_BITS
      if mode == MODE_DMA_W && @fifo.empty?
        @stat |= SPUSTAT_DMA_REQUEST | SPUSTAT_DMA_WRITE_REQUEST
      end
    end

    def tick_sample
      left_sum = 0
      right_sum = 0
      update_noise

      24.times do |voice_index|
        next if (@voice_active & (1 << voice_index)).zero?

        voice = @voices[voice_index]
        pitch = modulated_pitch(voice_index, read16(0xC00 + voice_index * 0x10 + 0x04))
        pitch = [pitch, 0x3FFF].min
        next if pitch.zero?

        sample = noise_enabled?(voice_index) ? signed16(@noise_level & 0xFFFF) : (voice.decoded_samples[voice.sample_index] || 0)
        volume = apply_volume(sample, voice.adsr_volume)
        voice.last_volume = volume
        left_sum += apply_volume(volume, voice.left_volume)
        right_sum += apply_volume(volume, voice.right_volume)
        tick_voice_volume_sweeps(voice)
        tick_voice_adsr(voice_index)

        voice.sample_counter += pitch
        while voice.sample_counter >= 0x1000
          voice.sample_counter -= 0x1000
          voice.sample_index += 1
          next if voice.sample_index < 28

          advance_voice_block(voice_index)
          break if (@voice_active & (1 << voice_index)).zero?
        end
      end

      if (@cnt & 0x0001) != 0
        cd_left = @cd_audio_fifo.shift || 0
        cd_right = @cd_audio_fifo.shift || 0
        left_sum += apply_volume(cd_left, signed16(@cd_audio_left_volume))
        right_sum += apply_volume(cd_right, signed16(@cd_audio_right_volume))
      end

      left_sum = apply_volume(clamp16(left_sum), @main_left_current_volume)
      right_sum = apply_volume(clamp16(right_sum), @main_right_current_volume)
      @pcm_sink&.call([clamp16(left_sum), clamp16(right_sum)].pack("s<*"))
      tick_main_volume_sweeps
    end

    def pitch_modulation_enabled?(voice_index)
      voice_index.positive? && (@pitch_modulation_enable & (1 << voice_index)) != 0
    end

    def modulated_pitch(voice_index, pitch)
      return pitch unless pitch_modulation_enabled?(voice_index)

      previous_volume = [[@voices[voice_index - 1].last_volume || 0, -0x8000].max, 0x7FFF].min
      ((signed16(pitch) * (previous_volume + 0x8000)) >> 15) & 0xFFFF
    end

    def decode_voice_block(voice_index)
      voice = @voices[voice_index]
      block = read_adpcm_block(voice.current_address)
      samples, last = decode_adpcm_block(block, voice.last_samples)
      voice.decoded_samples = samples
      voice.last_samples = last
      voice.current_block_flags = block[:flags]
      voice.repeat_address = voice.current_address if (block[:flags] & 0x04) != 0 && !voice.ignore_loop_address
    end

    def advance_voice_block(voice_index)
      mask = 1 << voice_index
      voice = @voices[voice_index]
      voice.sample_index -= 28
      voice.current_address = (voice.current_address + 2) & 0xFFFF
      voice.is_first_block = false

      if (voice.current_block_flags & 0x01) != 0
        @endx |= mask
        voice.current_address = voice.repeat_address & ~1
        @voice_active &= ~mask if (voice.current_block_flags & 0x02).zero? && !noise_enabled?(voice_index)
      end

      decode_voice_block(voice_index) if (@voice_active & mask) != 0
    end

    def noise_enabled?(voice_index)
      (@noise_mode_enable & (1 << voice_index)) != 0
    end

    def update_noise
      noise_wave_add = [
        1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0,
        1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0,
        0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1,
        0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1
      ]
      noise_freq_add = [0, 84, 140, 180, 210]
      noise_clock = (@cnt >> 8) & 0x3F
      level = (0x8000 >> (noise_clock >> 2)) << 16

      @noise_count += 0x10000 + noise_freq_add[noise_clock & 3]
      if (@noise_count & 0xFFFF) >= noise_freq_add[4]
        @noise_count += 0x10000
        @noise_count -= noise_freq_add[noise_clock & 3]
      end

      return if @noise_count < level

      @noise_count %= level
      @noise_level = ((@noise_level << 1) | noise_wave_add[(@noise_level >> 10) & 63]) & 0xFFFF_FFFF
    end

    def tick_voice_adsr(voice_index)
      voice = @voices[voice_index]
      return if voice.adsr_phase == :off

      tick_adsr_envelope(voice)
      adsr_offset = voice_index * 0x10 + 0x0C
      @regs.setbyte(adsr_offset, voice.adsr_volume & 0xFF)
      @regs.setbyte(adsr_offset + 1, (voice.adsr_volume >> 8) & 0xFF)

      reached_target =
        if voice.adsr_envelope[:decreasing]
          voice.adsr_volume <= voice.adsr_target
        else
          voice.adsr_volume >= voice.adsr_target
        end
      return unless reached_target && voice.adsr_phase != :sustain

      voice.adsr_phase = next_adsr_phase(voice.adsr_phase)
      if voice.adsr_phase == :off
        @voice_active &= ~(1 << voice_index)
      else
        update_adsr_envelope(voice_index)
      end
    end

    def update_adsr_envelope(voice_index)
      voice = @voices[voice_index]
      adsr = read16(0xC00 + voice_index * 0x10 + 0x08) |
             (read16(0xC00 + voice_index * 0x10 + 0x0A) << 16)

      case voice.adsr_phase
      when :attack
        rate = (adsr >> 8) & 0x7F
        voice.adsr_target = 0x7FFF
        voice.adsr_envelope = reset_volume_envelope(rate, 0x7F, false, (adsr & (1 << 15)) != 0, false)
      when :decay
        sustain_level = adsr & 0x0F
        rate = ((adsr >> 4) & 0x0F) << 2
        voice.adsr_target = [(sustain_level + 1) * 0x800, 0x7FFF].min
        voice.adsr_envelope = reset_volume_envelope(rate, 0x1F << 2, true, true, false)
      when :sustain
        rate = (adsr >> 22) & 0x7F
        voice.adsr_target = 0
        voice.adsr_envelope = reset_volume_envelope(rate, 0x7F, (adsr & (1 << 30)) != 0, (adsr & (1 << 31)) != 0, false)
      when :release
        rate = ((adsr >> 16) & 0x1F) << 2
        voice.adsr_target = 0
        voice.adsr_envelope = reset_volume_envelope(rate, 0x1F << 2, true, (adsr & (1 << 21)) != 0, false)
      else
        voice.adsr_target = 0
        voice.adsr_envelope = reset_volume_envelope(0, 0, false, false, false)
      end
    end

    def next_adsr_phase(phase)
      case phase
      when :attack then :decay
      when :decay then :sustain
      when :release then :off
      else :sustain
      end
    end

    def reset_volume_envelope(rate, rate_mask, decreasing, exponential, phase_invert)
      phase_invert &&= !(decreasing && exponential)
      base_step = 7 - (rate & 3)
      step = ((decreasing ^ phase_invert) || (decreasing && exponential)) ? ~base_step : base_step
      counter_increment = 0x8000

      if rate < 44
        step <<= 11 - (rate >> 2)
      elsif rate >= 48
        counter_increment >>= (rate >> 2) - 11
        counter_increment = [counter_increment, 1].max if (rate & rate_mask) != rate_mask
      end

      {
        rate: rate,
        decreasing: decreasing,
        exponential: exponential,
        phase_invert: phase_invert,
        counter: 0,
        counter_increment: counter_increment,
        step: step,
      }
    end

    def tick_adsr_envelope(voice)
      envelope = voice.adsr_envelope
      increment = envelope[:counter_increment]
      step = envelope[:step]

      if envelope[:exponential]
        if envelope[:decreasing]
          step = (step * voice.adsr_volume) >> 15
        elsif voice.adsr_volume >= 0x6000
          rate = envelope[:rate]
          if rate < 40
            step >>= 2
          elsif rate >= 44
            increment >>= 2
          else
            step >>= 1
            increment >>= 1
          end
        end
      end

      envelope[:counter] += increment
      return if (envelope[:counter] & 0x8000).zero?

      envelope[:counter] = 0
      new_level = voice.adsr_volume + step
      if envelope[:decreasing]
        new_level = envelope[:phase_invert] ? [[new_level, -32_768].max, 0].min : [new_level, 0].max
      else
        new_level = [[new_level, -32_768].max, 32_767].min
      end
      voice.adsr_volume = new_level
    end

    def apply_volume(sample, volume)
      (sample * volume) >> 15
    end

    def reset_volume_sweep(register, current_level)
      if (register & 0x8000).zero?
        return [
          fixed_volume_level(register),
          reset_volume_envelope(0, 0x7F, false, false, false),
          false,
        ]
      end

      envelope = reset_volume_envelope(
        register & 0x7F,
        0x7F,
        (register & (1 << 13)) != 0,
        (register & (1 << 14)) != 0,
        (register & (1 << 12)) != 0
      )
      [current_level, envelope, envelope[:counter_increment].positive?]
    end

    def fixed_volume_level(register)
      value = register & 0x7FFF
      value -= 0x8000 if (value & 0x4000) != 0
      value * 2
    end

    def tick_main_volume_sweeps
      if @main_left_volume_sweep_active
        @main_left_current_volume, @main_left_volume_sweep_active =
          tick_volume_sweep(@main_left_current_volume, @main_left_volume_envelope)
      end
      return unless @main_right_volume_sweep_active

      @main_right_current_volume, @main_right_volume_sweep_active =
        tick_volume_sweep(@main_right_current_volume, @main_right_volume_envelope)
    end

    def tick_voice_volume_sweeps(voice)
      if voice.left_volume_sweep_active
        voice.left_volume, voice.left_volume_sweep_active =
          tick_volume_sweep(voice.left_volume, voice.left_volume_envelope)
      end
      return unless voice.right_volume_sweep_active

      voice.right_volume, voice.right_volume_sweep_active =
        tick_volume_sweep(voice.right_volume, voice.right_volume_envelope)
    end

    def tick_volume_sweep(current_level, envelope)
      increment = envelope[:counter_increment]
      step = envelope[:step]

      if envelope[:exponential]
        if envelope[:decreasing]
          step = (step * current_level) >> 15
        elsif current_level >= 0x6000
          rate = envelope[:rate]
          if rate < 40
            step >>= 2
          elsif rate >= 44
            increment >>= 2
          else
            step >>= 1
            increment >>= 1
          end
        end
      end

      envelope[:counter] += increment
      return [current_level, true] if (envelope[:counter] & 0x8000).zero?

      envelope[:counter] = 0
      new_level = current_level + step
      if envelope[:decreasing]
        if envelope[:phase_invert]
          new_level = [[new_level, -32_768].max, 0].min
        else
          new_level = [new_level, 0].max
        end
        [new_level, new_level == 0]
      else
        new_level = [[new_level, -32_768].max, 32_767].min
        active = new_level != (step.negative? ? -32_768 : 32_767)
        [new_level, active]
      end
    end

    def read_current_voice_volume(offset)
      return nil unless offset >= CURRENT_VOICE_VOL_BASE && offset < CURRENT_VOICE_VOL_BASE + 24 * 4

      voice = @voices[(offset - CURRENT_VOICE_VOL_BASE) / 4]
      ((offset & 0x02).zero? ? voice.left_volume : voice.right_volume) & 0xFFFF
    end

    def read_reverb_register(offset)
      return nil unless offset >= REVERB_REG_BASE && offset < REVERB_REG_END

      @reverb_registers[(offset - REVERB_REG_BASE) / 2]
    end

    def write_reverb_register(offset, value)
      return false unless offset >= REVERB_REG_BASE && offset < REVERB_REG_END

      @reverb_registers[(offset - REVERB_REG_BASE) / 2] = value
      true
    end

    def signed16(value)
      value >= 0x8000 ? value - 0x1_0000 : value
    end

    def clamp16(value)
      [[value, -32_768].max, 32_767].min
    end
  end
end
