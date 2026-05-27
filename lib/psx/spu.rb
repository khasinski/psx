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
    PITCH_MOD_LOW     = 0xD90
    PITCH_MOD_HIGH    = 0xD92
    CD_AUDIO_VOL_LEFT = 0xDB0
    CD_AUDIO_VOL_RIGHT = 0xDB2
    CYCLES_PER_SAMPLE = 768

    # SPUCNT bits 4-5 = transfer mode
    MODE_STOP   = 0
    MODE_MANUAL = 1
    MODE_DMA_W  = 2
    MODE_DMA_R  = 3
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
      @pitch_modulation_enable = 0
      @cd_audio_left_volume = 0
      @cd_audio_right_volume = 0
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
          last_volume: 0
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
      when SPU_TRANSFER_ADDR then @transfer_addr >> 3
      when SPUCNT            then @cnt
      when SPUDTC            then @dtc
      when SPUSTAT           then @stat
      when CD_AUDIO_VOL_LEFT then @cd_audio_left_volume
      when CD_AUDIO_VOL_RIGHT then @cd_audio_right_volume
      else
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
        end
      when SPUCNT
        prev_mode = mode
        @cnt = v
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
      when SPUDTC
        @dtc = v
      when MAIN_VOL_LEFT
        @main_left_volume = v
      when MAIN_VOL_RIGHT
        @main_right_volume = v
      when PITCH_MOD_LOW
        @pitch_modulation_enable = (@pitch_modulation_enable & 0xFFFF_0000) | v
      when PITCH_MOD_HIGH
        @pitch_modulation_enable = (@pitch_modulation_enable & 0x0000_FFFF) | (v << 16)
      when CD_AUDIO_VOL_LEFT
        @cd_audio_left_volume = v
      when CD_AUDIO_VOL_RIGHT
        @cd_audio_right_volume = v
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
    end

    def tick_sample
      left_sum = 0
      right_sum = 0

      24.times do |voice_index|
        next if (@voice_active & (1 << voice_index)).zero?

        voice = @voices[voice_index]
        pitch = modulated_pitch(voice_index, read16(0xC00 + voice_index * 0x10 + 0x04))
        pitch = [pitch, 0x3FFF].min
        next if pitch.zero?

        sample = voice.decoded_samples[voice.sample_index] || 0
        volume = apply_volume(sample, voice.adsr_volume)
        voice.last_volume = volume
        left_sum += apply_volume(volume, signed16(read16(0xC00 + voice_index * 0x10)))
        right_sum += apply_volume(volume, signed16(read16(0xC00 + voice_index * 0x10 + 0x02)))
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

      left_sum = apply_volume(clamp16(left_sum), signed16(@main_left_volume))
      right_sum = apply_volume(clamp16(right_sum), signed16(@main_right_volume))
      @pcm_sink&.call([clamp16(left_sum), clamp16(right_sum)].pack("s<*"))
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
      voice.repeat_address = voice.current_address if (block[:flags] & 0x04) != 0
    end

    def advance_voice_block(voice_index)
      mask = 1 << voice_index
      voice = @voices[voice_index]
      voice.sample_index -= 28
      voice.current_address = (voice.current_address + 2) & 0xFFFF

      if (voice.current_block_flags & 0x01) != 0
        @endx |= mask
        voice.current_address = voice.repeat_address & ~1
        @voice_active &= ~mask if (voice.current_block_flags & 0x02).zero?
      end

      decode_voice_block(voice_index) if (@voice_active & mask) != 0
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

    def signed16(value)
      value >= 0x8000 ? value - 0x1_0000 : value
    end

    def clamp16(value)
      [[value, -32_768].max, 32_767].min
    end
  end
end
