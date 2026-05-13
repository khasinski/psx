# frozen_string_literal: true

module PSX
  # SPU stub — enough to satisfy programs that probe SPUCNT/SPUSTAT and to
  # round-trip data through SPU RAM via FIFO and DMA channel 4.
  #
  # No audio synthesis. Voice/reverb/etc. registers read back as zero.
  class SPU
    RAM_SIZE = 512 * 1024

    # IO offsets relative to 0x1F801000
    SPU_TRANSFER_ADDR = 0xDA6
    SPU_FIFO          = 0xDA8
    SPUCNT            = 0xDAA
    SPUDTC            = 0xDAC
    SPUSTAT           = 0xDAE

    # SPUCNT bits 4-5 = transfer mode
    MODE_STOP   = 0
    MODE_MANUAL = 1
    MODE_DMA_W  = 2
    MODE_DMA_R  = 3

    def initialize
      @ram = ("\x00" * RAM_SIZE).b
      @transfer_addr = 0   # latched value (byte address)
      @current_addr  = 0   # advances during transfers
      @cnt = 0
      @stat = 0
      @dtc = 0
      @fifo = []
    end

    def read16(offset)
      case offset
      when SPU_TRANSFER_ADDR then @transfer_addr >> 3
      when SPUCNT            then @cnt
      when SPUDTC            then @dtc
      when SPUSTAT           then @stat
      else 0
      end
    end

    def write16(offset, value)
      v = value & 0xFFFF
      case offset
      when SPU_TRANSFER_ADDR
        @transfer_addr = (v * 8) & (RAM_SIZE - 1)
        @current_addr = @transfer_addr
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
        word |= @ram.getbyte(@current_addr) << (i * 8)
        @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
      end
      word
    end

    def dma_write_word(word)
      4.times do |i|
        @ram.setbyte(@current_addr, (word >> (i * 8)) & 0xFF)
        @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
      end
    end

    private

    def mode
      (@cnt >> 4) & 0x3
    end

    def write_word_to_ram(v)
      @ram.setbyte(@current_addr, v & 0xFF)
      @current_addr = (@current_addr + 1) & (RAM_SIZE - 1)
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
