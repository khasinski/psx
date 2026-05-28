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
    CAPTURE_BUFFER_SIZE_PER_CHANNEL = 0x400
    CYCLES_PER_SAMPLE = 768
    REVERB_RESAMPLE_COEFF = [
      -0x0001, 0x0002, -0x000A, 0x0023, -0x0067,
      0x010A, -0x0268, 0x0534, -0x0B90, 0x2806,
      0x2806, -0x0B90, 0x0534, -0x0268, 0x010A,
      -0x0067, 0x0023, -0x000A, 0x0002, -0x0001
    ].freeze
    GAUSS = [
      -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001,
      -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001, -0x001,
      0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0001,
      0x0001, 0x0001, 0x0001, 0x0002, 0x0002, 0x0002, 0x0003, 0x0003,
      0x0003, 0x0004, 0x0004, 0x0005, 0x0005, 0x0006, 0x0007, 0x0007,
      0x0008, 0x0009, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E,
      0x000F, 0x0010, 0x0011, 0x0012, 0x0013, 0x0015, 0x0016, 0x0018,
      0x0019, 0x001B, 0x001C, 0x001E, 0x0020, 0x0021, 0x0023, 0x0025,
      0x0027, 0x0029, 0x002C, 0x002E, 0x0030, 0x0033, 0x0035, 0x0038,
      0x003A, 0x003D, 0x0040, 0x0043, 0x0046, 0x0049, 0x004D, 0x0050,
      0x0054, 0x0057, 0x005B, 0x005F, 0x0063, 0x0067, 0x006B, 0x006F,
      0x0074, 0x0078, 0x007D, 0x0082, 0x0087, 0x008C, 0x0091, 0x0096,
      0x009C, 0x00A1, 0x00A7, 0x00AD, 0x00B3, 0x00BA, 0x00C0, 0x00C7,
      0x00CD, 0x00D4, 0x00DB, 0x00E3, 0x00EA, 0x00F2, 0x00FA, 0x0101,
      0x010A, 0x0112, 0x011B, 0x0123, 0x012C, 0x0135, 0x013F, 0x0148,
      0x0152, 0x015C, 0x0166, 0x0171, 0x017B, 0x0186, 0x0191, 0x019C,
      0x01A8, 0x01B4, 0x01C0, 0x01CC, 0x01D9, 0x01E5, 0x01F2, 0x0200,
      0x020D, 0x021B, 0x0229, 0x0237, 0x0246, 0x0255, 0x0264, 0x0273,
      0x0283, 0x0293, 0x02A3, 0x02B4, 0x02C4, 0x02D6, 0x02E7, 0x02F9,
      0x030B, 0x031D, 0x0330, 0x0343, 0x0356, 0x036A, 0x037E, 0x0392,
      0x03A7, 0x03BC, 0x03D1, 0x03E7, 0x03FC, 0x0413, 0x042A, 0x0441,
      0x0458, 0x0470, 0x0488, 0x04A0, 0x04B9, 0x04D2, 0x04EC, 0x0506,
      0x0520, 0x053B, 0x0556, 0x0572, 0x058E, 0x05AA, 0x05C7, 0x05E4,
      0x0601, 0x061F, 0x063E, 0x065C, 0x067C, 0x069B, 0x06BB, 0x06DC,
      0x06FD, 0x071E, 0x0740, 0x0762, 0x0784, 0x07A7, 0x07CB, 0x07EF,
      0x0813, 0x0838, 0x085D, 0x0883, 0x08A9, 0x08D0, 0x08F7, 0x091E,
      0x0946, 0x096F, 0x0998, 0x09C1, 0x09EB, 0x0A16, 0x0A40, 0x0A6C,
      0x0A98, 0x0AC4, 0x0AF1, 0x0B1E, 0x0B4C, 0x0B7A, 0x0BA9, 0x0BD8,
      0x0C07, 0x0C38, 0x0C68, 0x0C99, 0x0CCB, 0x0CFD, 0x0D30, 0x0D63,
      0x0D97, 0x0DCB, 0x0E00, 0x0E35, 0x0E6B, 0x0EA1, 0x0ED7, 0x0F0F,
      0x0F46, 0x0F7F, 0x0FB7, 0x0FF1, 0x102A, 0x1065, 0x109F, 0x10DB,
      0x1116, 0x1153, 0x118F, 0x11CD, 0x120B, 0x1249, 0x1288, 0x12C7,
      0x1307, 0x1347, 0x1388, 0x13C9, 0x140B, 0x144D, 0x1490, 0x14D4,
      0x1517, 0x155C, 0x15A0, 0x15E6, 0x162C, 0x1672, 0x16B9, 0x1700,
      0x1747, 0x1790, 0x17D8, 0x1821, 0x186B, 0x18B5, 0x1900, 0x194B,
      0x1996, 0x19E2, 0x1A2E, 0x1A7B, 0x1AC8, 0x1B16, 0x1B64, 0x1BB3,
      0x1C02, 0x1C51, 0x1CA1, 0x1CF1, 0x1D42, 0x1D93, 0x1DE5, 0x1E37,
      0x1E89, 0x1EDC, 0x1F2F, 0x1F82, 0x1FD6, 0x202A, 0x207F, 0x20D4,
      0x2129, 0x217F, 0x21D5, 0x222C, 0x2282, 0x22DA, 0x2331, 0x2389,
      0x23E1, 0x2439, 0x2492, 0x24EB, 0x2545, 0x259E, 0x25F8, 0x2653,
      0x26AD, 0x2708, 0x2763, 0x27BE, 0x281A, 0x2876, 0x28D2, 0x292E,
      0x298B, 0x29E7, 0x2A44, 0x2AA1, 0x2AFF, 0x2B5C, 0x2BBA, 0x2C18,
      0x2C76, 0x2CD4, 0x2D33, 0x2D91, 0x2DF0, 0x2E4F, 0x2EAE, 0x2F0D,
      0x2F6C, 0x2FCC, 0x302B, 0x308B, 0x30EA, 0x314A, 0x31AA, 0x3209,
      0x3269, 0x32C9, 0x3329, 0x3389, 0x33E9, 0x3449, 0x34A9, 0x3509,
      0x3569, 0x35C9, 0x3629, 0x3689, 0x36E8, 0x3748, 0x37A8, 0x3807,
      0x3867, 0x38C6, 0x3926, 0x3985, 0x39E4, 0x3A43, 0x3AA2, 0x3B00,
      0x3B5F, 0x3BBD, 0x3C1B, 0x3C79, 0x3CD7, 0x3D35, 0x3D92, 0x3DEF,
      0x3E4C, 0x3EA9, 0x3F05, 0x3F62, 0x3FBD, 0x4019, 0x4074, 0x40D0,
      0x412A, 0x4185, 0x41DF, 0x4239, 0x4292, 0x42EB, 0x4344, 0x439C,
      0x43F4, 0x444C, 0x44A3, 0x44FA, 0x4550, 0x45A6, 0x45FC, 0x4651,
      0x46A6, 0x46FA, 0x474E, 0x47A1, 0x47F4, 0x4846, 0x4898, 0x48E9,
      0x493A, 0x498A, 0x49D9, 0x4A29, 0x4A77, 0x4AC5, 0x4B13, 0x4B5F,
      0x4BAC, 0x4BF7, 0x4C42, 0x4C8D, 0x4CD7, 0x4D20, 0x4D68, 0x4DB0,
      0x4DF7, 0x4E3E, 0x4E84, 0x4EC9, 0x4F0E, 0x4F52, 0x4F95, 0x4FD7,
      0x5019, 0x505A, 0x509A, 0x50DA, 0x5118, 0x5156, 0x5194, 0x51D0,
      0x520C, 0x5247, 0x5281, 0x52BA, 0x52F3, 0x532A, 0x5361, 0x5397,
      0x53CC, 0x5401, 0x5434, 0x5467, 0x5499, 0x54CA, 0x54FA, 0x5529,
      0x5558, 0x5585, 0x55B2, 0x55DE, 0x5609, 0x5632, 0x565B, 0x5684,
      0x56AB, 0x56D1, 0x56F6, 0x571B, 0x573E, 0x5761, 0x5782, 0x57A3,
      0x57C3, 0x57E2, 0x57FF, 0x581C, 0x5838, 0x5853, 0x586D, 0x5886,
      0x589E, 0x58B5, 0x58CB, 0x58E0, 0x58F4, 0x5907, 0x5919, 0x592A,
      0x593A, 0x5949, 0x5958, 0x5965, 0x5971, 0x597C, 0x5986, 0x598F,
      0x5997, 0x599E, 0x59A4, 0x59A9, 0x59AD, 0x59B0, 0x59B2, 0x59B3
    ].freeze

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
      :interpolation_samples,
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
      @capture_buffer_position = 0
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
      @reverb_current_address = 0
      @reverb_resample_position = 0
      @reverb_downsample_buffer = [Array.new(128, 0), Array.new(128, 0)]
      @reverb_upsample_buffer = [Array.new(64, 0), Array.new(64, 0)]
      @last_reverb_input = [0, 0]
      @last_reverb_output = [0, 0]
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
          interpolation_samples: [0, 0, 0],
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
        check_late_ram_irqs if irq_enabled?
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
          check_late_ram_irqs
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
        @reverb_current_address = reverb_base_address
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

    def irq9_control_enabled?
      (@cnt & (1 << 6)) != 0
    end

    def irq_transfer_match?(addr)
      ((@irq_addr * 8) & (RAM_SIZE - 1)) == (addr & (RAM_SIZE - 1))
    end

    def trigger_ram_irq
      @stat |= (1 << 6)
      @interrupts&.request(Interrupts::IRQ_SPU)
    end

    def check_late_ram_irqs
      if irq_transfer_match?(@current_addr)
        trigger_ram_irq
        return
      end

      @voices.each do |voice|
        next if voice.decoded_samples.empty?

        ram_address = (voice.current_address * 8) & (RAM_SIZE - 1)
        if irq_transfer_match?(ram_address) || irq_transfer_match?(ram_address + 8)
          trigger_ram_irq
          return
        end
      end
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
        @voices[voice].interpolation_samples = [0, 0, 0]
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

        next if @voices[voice].adsr_phase == :off || @voices[voice].adsr_phase == :release

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
      reverb_in_left = 0
      reverb_in_right = 0
      @key_on = 0
      @key_off = 0
      update_noise
      cd_capture_left = 0
      cd_capture_right = 0

      24.times do |voice_index|
        voice = @voices[voice_index]
        voice_active = (@voice_active & (1 << voice_index)) != 0
        unless voice_active || irq9_control_enabled?
          voice.last_volume = 0
          next
        end

        decode_voice_block(voice_index) if voice.decoded_samples.empty?
        pitch = modulated_pitch(voice_index, read16(0xC00 + voice_index * 0x10 + 0x04))
        pitch = [pitch, 0x3FFF].min

        sample = noise_enabled?(voice_index) ? signed16(@noise_level & 0xFFFF) : interpolate_voice_sample(voice)
        volume = apply_volume(sample, voice.adsr_volume)
        voice.last_volume = volume
        left = apply_volume(volume, voice.left_volume)
        right = apply_volume(volume, voice.right_volume)
        if voice_active
          left_sum += left
          right_sum += right
        end
        if voice_active && reverb_enabled?(voice_index)
          reverb_in_left += left
          reverb_in_right += right
        end
        tick_voice_volume_sweeps(voice)
        tick_voice_adsr(voice_index) if voice_active

        voice.sample_counter += pitch
        while voice.sample_counter >= 0x1000
          voice.sample_counter -= 0x1000
          voice.sample_index += 1
          next if voice.sample_index < 28

          advance_voice_block(voice_index)
          break if (@voice_active & (1 << voice_index)).zero?
        end
      end

      unless mute_enabled?
        left_sum = 0
        right_sum = 0
        reverb_in_left = 0
        reverb_in_right = 0
      end

      if (@cnt & 0x0001) != 0
        cd_left = @cd_audio_fifo.shift || 0
        cd_right = @cd_audio_fifo.shift || 0
        cd_capture_left = cd_left
        cd_capture_right = cd_right
        cd_left_volume = apply_volume(cd_left, signed16(@cd_audio_left_volume))
        cd_right_volume = apply_volume(cd_right, signed16(@cd_audio_right_volume))
        left_sum += cd_left_volume
        right_sum += cd_right_volume
        if cd_audio_reverb_enabled?
          reverb_in_left += cd_left_volume
          reverb_in_right += cd_right_volume
        end
      end

      reverb_left, reverb_right = process_reverb(clamp16(reverb_in_left), clamp16(reverb_in_right))
      left_sum += reverb_left
      right_sum += reverb_right

      left_sum = apply_volume(clamp16(left_sum), @main_left_current_volume)
      right_sum = apply_volume(clamp16(right_sum), @main_right_current_volume)
      @pcm_sink&.call([clamp16(left_sum), clamp16(right_sum)].pack("s<*"))
      tick_main_volume_sweeps
      write_capture_buffers(cd_capture_left, cd_capture_right)
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
      previous_tail = (voice.interpolation_samples || [0, 0, 0]).last(3)
      samples, last = decode_adpcm_block(block, voice.last_samples)
      voice.decoded_samples = samples
      voice.interpolation_samples = previous_tail + samples
      voice.last_samples = last
      voice.current_block_flags = block[:flags]
      voice.repeat_address = voice.current_address if (block[:flags] & 0x04) != 0 && !voice.ignore_loop_address
    end

    def interpolate_voice_sample(voice)
      sample_index = voice.sample_index
      samples = voice.interpolation_samples
      samples = [0, 0, 0] + voice.decoded_samples if samples.nil? || samples.length < sample_index + 4
      interpolation_index = (voice.sample_counter >> 4) & 0xFF
      base = sample_index
      out = GAUSS[0x0FF - interpolation_index] * (samples[base] || 0)
      out += GAUSS[0x1FF - interpolation_index] * (samples[base + 1] || 0)
      out += GAUSS[0x100 + interpolation_index] * (samples[base + 2] || 0)
      out += GAUSS[0x000 + interpolation_index] * (samples[base + 3] || 0)
      out >> 15
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
        if (voice.current_block_flags & 0x02).zero? && !noise_enabled?(voice_index)
          @voice_active &= ~mask
          voice.adsr_phase = :off
          voice.adsr_volume = 0
          adsr_offset = voice_index * 0x10 + 0x0C
          @regs.setbyte(adsr_offset, 0)
          @regs.setbyte(adsr_offset + 1, 0)
        end
      end

      if (@voice_active & mask) != 0
        decode_voice_block(voice_index)
      else
        voice.decoded_samples = []
      end
    end

    def noise_enabled?(voice_index)
      (@noise_mode_enable & (1 << voice_index)) != 0
    end

    def reverb_enabled?(voice_index)
      (@reverb_on_enable & (1 << voice_index)) != 0
    end

    def reverb_master_enabled?
      (@cnt & (1 << 7)) != 0
    end

    def cd_audio_reverb_enabled?
      (@cnt & (1 << 2)) != 0
    end

    def mute_enabled?
      (@cnt & (1 << 14)) != 0
    end

    def reverb_base_address
      (@reverb_base << 2) & ((RAM_SIZE - 1) / 2)
    end

    def process_reverb(left_in, right_in)
      @last_reverb_input = [left_in, right_in]
      @reverb_downsample_buffer[0][@reverb_resample_position] = left_in
      @reverb_downsample_buffer[0][@reverb_resample_position | 0x40] = left_in
      @reverb_downsample_buffer[1][@reverb_resample_position] = right_in
      @reverb_downsample_buffer[1][@reverb_resample_position | 0x40] = right_in

      out = [0, 0]

      if @reverb_resample_position.odd?
        downsampled = 2.times.map { |channel| reverb_downsample(channel) }
        2.times do |channel|
          process_reverb_channel(channel, downsampled[channel])
          src = @reverb_upsample_buffer[channel]
          base = (((@reverb_resample_position >> 1) - 19) & 0x1F)
          out[channel] = clamp16(REVERB_RESAMPLE_COEFF.each_with_index.sum { |coef, i| coef * src[base + i] } >> 14)
        end

        @reverb_current_address = (@reverb_current_address + 1) & ((RAM_SIZE - 1) / 2)
        @reverb_current_address = reverb_base_address if @reverb_current_address.zero?
      else
        index = (((@reverb_resample_position >> 1) - 19) & 0x1F) + 9
        out = [@reverb_upsample_buffer[0][index], @reverb_upsample_buffer[1][index]]
      end
      @reverb_resample_position = (@reverb_resample_position + 1) & 0x3F
      @last_reverb_output = [
        apply_volume(out[0], signed16(@reverb_left_volume)),
        apply_volume(out[1], signed16(@reverb_right_volume)),
      ]
    end

    def reverb_downsample(channel)
      src = @reverb_downsample_buffer[channel]
      base = (@reverb_resample_position - 38) & 0x3F
      sum = REVERB_RESAMPLE_COEFF.each_with_index.sum { |coef, i| coef * src[base + i] }
      clamp16((sum + (0x4000 * src[base + 19])) >> 15)
    end

    def process_reverb_channel(channel, downsampled)
      if reverb_master_enabled?
        iir_input_a = clamp16((((reverb_read(reverb_reg(16 + channel)) * reverb_reg_s(7)) >> 14) +
                              ((downsampled * reverb_reg_s(30 + channel)) >> 14)) >> 1)
        iir_input_b = clamp16((((reverb_read(reverb_reg(24 + (channel ^ 1))) * reverb_reg_s(7)) >> 14) +
                              ((downsampled * reverb_reg_s(30 + channel)) >> 14)) >> 1)
        iir_a = clamp16((((iir_input_a * reverb_reg_s(2)) >> 14) +
                         (reverb_iir_alpha_complement(reverb_read(reverb_reg(10 + channel), -1)) >> 14)) >> 1)
        iir_b = clamp16((((iir_input_b * reverb_reg_s(2)) >> 14) +
                         (reverb_iir_alpha_complement(reverb_read(reverb_reg(18 + channel), -1)) >> 14)) >> 1)

        reverb_write(reverb_reg(10 + channel), iir_a)
        reverb_write(reverb_reg(18 + channel), iir_b)
      end

      acc =
        ((reverb_read(reverb_reg(12 + channel)) * reverb_reg_s(3)) >> 14) +
        ((reverb_read(reverb_reg(14 + channel)) * reverb_reg_s(4)) >> 14) +
        ((reverb_read(reverb_reg(20 + channel)) * reverb_reg_s(5)) >> 14) +
        ((reverb_read(reverb_reg(22 + channel)) * reverb_reg_s(6)) >> 14)
      fb_a = reverb_read((reverb_reg(26 + channel) - reverb_reg(0)) & 0xFFFF)
      fb_b = reverb_read((reverb_reg(28 + channel) - reverb_reg(1)) & 0xFFFF)
      mda = clamp16((acc + ((fb_a * reverb_neg(reverb_reg_s(8))) >> 14)) >> 1)
      mdb = clamp16(fb_a + ((((mda * reverb_reg_s(8)) >> 14) +
                             ((fb_b * reverb_neg(reverb_reg_s(9))) >> 14)) >> 1))

      sample = clamp16(fb_b + ((mdb * reverb_reg_s(9)) >> 15))
      index = @reverb_resample_position >> 1
      @reverb_upsample_buffer[channel][index] = sample
      @reverb_upsample_buffer[channel][index | 0x20] = sample

      if reverb_master_enabled?
        reverb_write(reverb_reg(26 + channel), mda)
        reverb_write(reverb_reg(28 + channel), mdb)
      end
    end

    def reverb_iir_alpha_complement(sample)
      alpha = reverb_reg_s(2)
      if alpha == -32_768
        sample == -32_768 ? 0 : sample * -65_536
      else
        sample * (32_768 - alpha)
      end
    end

    def reverb_neg(sample)
      sample == -32_768 ? 0x7FFF : -sample
    end

    def reverb_reg(index)
      @reverb_registers[index] & 0xFFFF
    end

    def reverb_reg_s(index)
      signed16(reverb_reg(index))
    end

    def reverb_read(address, offset = 0)
      read_ram_s16(reverb_memory_address(((address & 0xFFFF) << 2) + offset))
    end

    def reverb_write(address, value)
      write_ram_s16(reverb_memory_address((address & 0xFFFF) << 2), clamp16(value))
    end

    def reverb_memory_address(offset)
      mask = (RAM_SIZE - 1) / 2
      halfword_offset = @reverb_current_address + (offset & mask)
      halfword_offset += reverb_base_address if (halfword_offset & 0x40000) != 0
      (halfword_offset & mask) * 2
    end

    def read_ram_s16(address)
      lo = @ram.getbyte(address & (RAM_SIZE - 1))
      hi = @ram.getbyte((address + 1) & (RAM_SIZE - 1))
      signed16(lo | (hi << 8))
    end

    def write_ram_s16(address, value)
      v = value & 0xFFFF
      @ram.setbyte(address & (RAM_SIZE - 1), v & 0xFF)
      @ram.setbyte((address + 1) & (RAM_SIZE - 1), (v >> 8) & 0xFF)
    end

    def write_capture_buffers(cd_left, cd_right)
      write_capture_buffer(0, cd_left)
      write_capture_buffer(1, cd_right)
      write_capture_buffer(2, clamp16(@voices[1].last_volume || 0))
      write_capture_buffer(3, clamp16(@voices[3].last_volume || 0))
      @capture_buffer_position = (@capture_buffer_position + 2) % CAPTURE_BUFFER_SIZE_PER_CHANNEL
      if @capture_buffer_position >= (CAPTURE_BUFFER_SIZE_PER_CHANNEL / 2)
        @stat |= (1 << 11)
      else
        @stat &= ~(1 << 11)
      end
    end

    def write_capture_buffer(index, value)
      address = (index * CAPTURE_BUFFER_SIZE_PER_CHANNEL) | @capture_buffer_position
      trigger_ram_irq if irq_enabled? && irq_transfer_match?(address)
      write_ram_s16(address, value)
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
