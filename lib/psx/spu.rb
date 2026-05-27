# frozen_string_literal: true

module PSX
  # SPU — partial register/DMA model. It satisfies programs that probe
  # SPUCNT/SPUSTAT, round-trips data through SPU RAM via FIFO and DMA
  # channel 4, and tracks basic voice key on/off state.
  #
  # Full audio synthesis is still TODO.
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

    # SPUCNT bits 4-5 = transfer mode
    MODE_STOP   = 0
    MODE_MANUAL = 1
    MODE_DMA_W  = 2
    MODE_DMA_R  = 3

    def initialize(interrupts: nil)
      @interrupts = interrupts
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
      when SPU_TRANSFER_ADDR then @transfer_addr >> 3
      when SPUCNT            then @cnt
      when SPUDTC            then @dtc
      when SPUSTAT           then @stat
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
      end
    end

    def key_off(mask)
      mask &= 0x00FF_FFFF
      @voice_active &= ~mask
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
  end
end
