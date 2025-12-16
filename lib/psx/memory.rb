# frozen_string_literal: true

module PSX
  class Memory
    # Memory regions (physical addresses)
    RAM_START       = 0x0000_0000
    RAM_SIZE        = 0x0020_0000  # 2 MB (mirrored 4x in 8 MB region)
    RAM_MIRROR_MASK = 0x001F_FFFF

    SCRATCHPAD_START = 0x1F80_0000
    SCRATCHPAD_SIZE  = 0x0000_0400  # 1 KB

    IO_START = 0x1F80_1000
    IO_SIZE  = 0x0000_2000

    BIOS_START = 0x1FC0_0000
    BIOS_SIZE  = 0x0008_0000  # 512 KB

    # Region masks for KSEG translation
    REGION_MASK = [
      0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,  # KUSEG: 0x0000_0000 - 0x7FFF_FFFF
      0x7FFF_FFFF,                                          # KSEG0: 0x8000_0000 - 0x9FFF_FFFF (cached)
      0x1FFF_FFFF,                                          # KSEG1: 0xA000_0000 - 0xBFFF_FFFF (uncached)
      0xFFFF_FFFF, 0xFFFF_FFFF                              # KSEG2: 0xC000_0000 - 0xFFFF_FFFF
    ].freeze

    attr_accessor :cache_isolated, :dma, :gpu

    def initialize(bios:, ram:, interrupts: nil, dma: nil, timers: nil)
      @bios = bios
      @ram = ram
      @interrupts = interrupts
      @dma = dma
      @timers = timers
      @gpu = nil  # Set later when GPU is created
      @scratchpad = ("\x00" * SCRATCHPAD_SIZE).b  # Force binary encoding
      @cache_isolated = false
    end

    def tick_dma
      @dma&.tick(self, gpu: @gpu)
    end

    def read8(addr)
      phys = translate(addr)
      region, offset = decode(phys)

      case region
      when :ram then @ram.read8(offset)
      when :bios then @bios.read8(offset)
      when :scratchpad then @scratchpad.getbyte(offset)
      when :io then io_read8(offset)
      when :expansion1, :expansion2 then 0xFF
      else
        warn format("Unhandled read8 at 0x%08X", addr)
        0
      end
    end

    def read16(addr)
      phys = translate(addr)
      region, offset = decode(phys)

      case region
      when :ram then @ram.read16(offset)
      when :bios then @bios.read16(offset)
      when :scratchpad
        @scratchpad.getbyte(offset) | (@scratchpad.getbyte(offset + 1) << 8)
      when :io then io_read16(offset)
      else
        warn format("Unhandled read16 at 0x%08X", addr)
        0
      end
    end

    def read32(addr)
      # Fast path: translate virtual to physical
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # Fast path for RAM (most common case)
      if phys < 0x0080_0000
        return @ram.read32(phys & RAM_MIRROR_MASK)
      end

      # Fast path for BIOS
      if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
        return @bios.read32(phys - BIOS_START)
      end

      # Slow path for everything else
      region, offset = decode(phys)

      case region
      when :scratchpad
        @scratchpad.byteslice(offset, 4).unpack1("V")
      when :io then io_read32(offset)
      when :cache_control then 0
      when :expansion1, :expansion2 then 0xFFFF_FFFF
      else
        warn format("Unhandled read32 at 0x%08X", addr)
        0
      end
    end

    def write8(addr, value)
      return if @cache_isolated  # Writes go to cache, not memory

      phys = translate(addr)
      region, offset = decode(phys)

      case region
      when :ram then @ram.write8(offset, value)
      when :scratchpad then @scratchpad.setbyte(offset, value & 0xFF)
      when :io then io_write8(offset, value)
      when :bios then warn format("Write to BIOS at 0x%08X", addr)
      else
        warn format("Unhandled write8 at 0x%08X = 0x%02X", addr, value)
      end
    end

    def write16(addr, value)
      return if @cache_isolated

      phys = translate(addr)
      region, offset = decode(phys)

      case region
      when :ram then @ram.write16(offset, value)
      when :scratchpad
        @scratchpad.setbyte(offset, value & 0xFF)
        @scratchpad.setbyte(offset + 1, (value >> 8) & 0xFF)
      when :io then io_write16(offset, value)
      when :bios then warn format("Write to BIOS at 0x%08X", addr)
      else
        warn format("Unhandled write16 at 0x%08X = 0x%04X", addr, value)
      end
    end

    def write32(addr, value)
      return if @cache_isolated

      # Fast path: translate virtual to physical
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # Fast path for RAM (most common case)
      if phys < 0x0080_0000
        @ram.write32(phys & RAM_MIRROR_MASK, value)
        return
      end

      # Slow path for everything else
      region, offset = decode(phys)

      case region
      when :scratchpad
        @scratchpad[offset, 4] = [value].pack("V")
      when :io then io_write32(offset, value)
      when :bios then warn format("Write to BIOS at 0x%08X", addr)
      when :cache_control
        # Cache control register - ignore writes
      when :expansion1, :expansion2
        # Expansion regions - ignore writes
      else
        warn format("Unhandled write32 at 0x%08X = 0x%08X", addr, value)
      end
    end

    private

    def translate(addr)
      # Mask address based on KSEG region
      region_index = (addr >> 29) & 0x7
      addr & REGION_MASK[region_index]
    end

    def decode(phys)
      case phys
      when 0x0000_0000...0x0080_0000
        # RAM (2 MB mirrored 4x)
        [:ram, phys & RAM_MIRROR_MASK]
      when 0x1F80_0000...0x1F80_0400
        [:scratchpad, phys - SCRATCHPAD_START]
      when 0x1F80_1000...0x1F80_3000
        [:io, phys - IO_START]
      when 0x1FC0_0000...0x1FC8_0000
        [:bios, phys - BIOS_START]
      when 0x1F00_0000...0x1F80_0000
        # Expansion Region 1
        [:expansion1, phys - 0x1F00_0000]
      when 0xFFFE_0000...0xFFFE_0200
        # Cache control
        [:cache_control, phys - 0xFFFE_0000]
      when 0x1F80_2000...0x1F80_2100
        # Expansion Region 2 (I/O ports)
        [:expansion2, phys - 0x1F80_2000]
      else
        [:unknown, phys]
      end
    end

    # I/O register stubs - will be expanded later
    def io_read8(offset)
      case offset
      when 0x1040...0x1050
        # Expansion 2 (POST/debug) - return 0
        0
      else
        # warn format("IO read8 at 0x%08X", IO_START + offset)
        0
      end
    end

    def io_read16(offset)
      case offset
      when 0x0044
        # Timer 0 counter
        0
      when 0x0054
        # Timer 1 counter
        0
      when 0x0064
        # Timer 2 counter
        0
      when 0x0C80...0x0D00
        # SPU status - return ready
        0
      when 0x0D80...0x0E00
        # SPU control
        0
      else
        # warn format("IO read16 at 0x%08X", IO_START + offset)
        0
      end
    end

    def io_read32(offset)
      case offset
      when 0x0000...0x0024
        # Memory control 1
        0
      when 0x0060
        # RAM size register
        0x0000_0B88
      when 0x0070
        # I_STAT - Interrupt status
        @interrupts&.read_stat || 0
      when 0x0074
        # I_MASK - Interrupt mask
        @interrupts&.read_mask || 0
      when 0x0080...0x00F0
        # DMA channel registers
        @dma&.read(offset - 0x0080) || 0
      when 0x00F0
        # DMA DPCR - control
        @dma&.dpcr || 0x0765_4321
      when 0x00F4
        # DMA DICR - interrupt control
        @dma&.dicr || 0
      when 0x0100...0x0130
        # Timers
        @timers&.read(offset - 0x0100) || 0
      when 0x0810
        # GPU GPUREAD
        @gpu&.read_data || 0
      when 0x0814
        # GPU GPUSTAT - return ready, display enabled
        @gpu&.status || 0x1C00_0000
      else
        # warn format("IO read32 at 0x%08X", IO_START + offset)
        0
      end
    end

    def io_write8(offset, value)
      case offset
      when 0x1040...0x1050
        # POST/debug output - could display but ignore for now
      else
        # warn format("IO write8 at 0x%08X = 0x%02X", IO_START + offset, value)
      end
    end

    def io_write16(offset, value)
      case offset
      when 0x0040...0x0070
        # Timers
      when 0x0C80...0x0E00
        # SPU registers
      else
        # warn format("IO write16 at 0x%08X = 0x%04X", IO_START + offset, value)
      end
    end

    def io_write32(offset, value)
      case offset
      when 0x0000...0x0024
        # Memory control 1 - ignore for now
      when 0x0060
        # RAM size config - ignore
      when 0x0070
        # I_STAT - Interrupt status (write acknowledges)
        @interrupts&.write_stat(value)
      when 0x0074
        # I_MASK - Interrupt mask
        @interrupts&.write_mask(value)
      when 0x0080...0x00F0
        # DMA channel registers
        @dma&.write(offset - 0x0080, value)
        # Check if this triggered a DMA transfer
        tick_dma
      when 0x00F0
        # DMA DPCR
        @dma&.write(0x70, value)
      when 0x00F4
        # DMA DICR
        @dma&.write(0x74, value)
      when 0x0100...0x0130
        # Timers
        @timers&.write(offset - 0x0100, value)
      when 0x0810
        # GPU GP0
        @gpu&.gp0(value)
      when 0x0814
        # GPU GP1
        @gpu&.gp1(value)
      else
        # warn format("IO write32 at 0x%08X = 0x%08X", IO_START + offset, value)
      end
    end
  end
end
