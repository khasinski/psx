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

    attr_accessor :cache_isolated, :dma, :gpu, :cdrom

    def initialize(bios:, ram:, interrupts: nil, dma: nil, timers: nil, cdrom: nil)
      @bios = bios
      @ram = ram
      @interrupts = interrupts
      @dma = dma
      @timers = timers
      @cdrom = cdrom
      @gpu = nil  # Set later when GPU is created
      @scratchpad = ("\x00" * SCRATCHPAD_SIZE).b  # Force binary encoding
      @cache_isolated = false
    end

    def tick_dma
      @dma&.tick(self, gpu: @gpu)
    end

    def read8(addr)
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # RAM (most common)
      return @ram.read8(phys & RAM_MIRROR_MASK) if phys < 0x0080_0000

      # BIOS
      return @bios.read8(phys - BIOS_START) if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000

      # Scratchpad
      if phys >= 0x1F80_0000 && phys < 0x1F80_0400
        return @scratchpad.getbyte(phys - SCRATCHPAD_START)
      end

      # I/O
      return io_read8(phys - IO_START) if phys >= 0x1F80_1000 && phys < 0x1F80_3000

      # Expansion regions
      return 0xFF if phys >= 0x1F00_0000 && phys < 0x1F80_0000
      return 0xFF if phys >= 0x1F80_2000 && phys < 0x1F80_2100

      0
    end

    def read16(addr)
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # RAM (most common)
      return @ram.read16(phys & RAM_MIRROR_MASK) if phys < 0x0080_0000

      # BIOS
      return @bios.read16(phys - BIOS_START) if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000

      # Scratchpad
      if phys >= 0x1F80_0000 && phys < 0x1F80_0400
        offset = phys - SCRATCHPAD_START
        return @scratchpad.getbyte(offset) | (@scratchpad.getbyte(offset + 1) << 8)
      end

      # I/O
      return io_read16(phys - IO_START) if phys >= 0x1F80_1000 && phys < 0x1F80_3000

      0
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

      # Scratchpad
      if phys >= 0x1F80_0000 && phys < 0x1F80_0400
        offset = phys - SCRATCHPAD_START
        return @scratchpad.getbyte(offset) |
               (@scratchpad.getbyte(offset + 1) << 8) |
               (@scratchpad.getbyte(offset + 2) << 16) |
               (@scratchpad.getbyte(offset + 3) << 24)
      end

      # I/O
      return io_read32(phys - IO_START) if phys >= 0x1F80_1000 && phys < 0x1F80_3000

      # Cache control
      return 0 if phys >= 0xFFFE_0000 && phys < 0xFFFE_0200

      # Expansion regions
      return 0xFFFF_FFFF if phys >= 0x1F00_0000 && phys < 0x1F80_0000
      return 0xFFFF_FFFF if phys >= 0x1F80_2000 && phys < 0x1F80_2100

      0
    end

    def write8(addr, value)
      return if @cache_isolated  # Writes go to cache, not memory

      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # RAM (most common)
      if phys < 0x0080_0000
        @ram.write8(phys & RAM_MIRROR_MASK, value)
        return
      end

      # Scratchpad
      if phys >= 0x1F80_0000 && phys < 0x1F80_0400
        @scratchpad.setbyte(phys - SCRATCHPAD_START, value & 0xFF)
        return
      end

      # I/O
      if phys >= 0x1F80_1000 && phys < 0x1F80_3000
        io_write8(phys - IO_START, value)
        return
      end

      # BIOS (read-only)
      warn format("Write to BIOS at 0x%08X", addr) if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
    end

    def write16(addr, value)
      return if @cache_isolated

      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # RAM (most common)
      if phys < 0x0080_0000
        @ram.write16(phys & RAM_MIRROR_MASK, value)
        return
      end

      # Scratchpad
      if phys >= 0x1F80_0000 && phys < 0x1F80_0400
        offset = phys - SCRATCHPAD_START
        @scratchpad.setbyte(offset, value & 0xFF)
        @scratchpad.setbyte(offset + 1, (value >> 8) & 0xFF)
        return
      end

      # I/O
      if phys >= 0x1F80_1000 && phys < 0x1F80_3000
        io_write16(phys - IO_START, value)
        return
      end

      # BIOS (read-only)
      warn format("Write to BIOS at 0x%08X", addr) if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
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

      # Scratchpad
      if phys >= 0x1F80_0000 && phys < 0x1F80_0400
        offset = phys - SCRATCHPAD_START
        @scratchpad.setbyte(offset, value & 0xFF)
        @scratchpad.setbyte(offset + 1, (value >> 8) & 0xFF)
        @scratchpad.setbyte(offset + 2, (value >> 16) & 0xFF)
        @scratchpad.setbyte(offset + 3, (value >> 24) & 0xFF)
        return
      end

      # I/O
      if phys >= 0x1F80_1000 && phys < 0x1F80_3000
        io_write32(phys - IO_START, value)
        return
      end

      # BIOS (read-only)
      if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
        warn format("Write to BIOS at 0x%08X", addr)
        return
      end

      # Cache control and expansion regions - ignore writes
    end

    private

    # I/O register stubs - will be expanded later
    def io_read8(offset)
      case offset
      when 0x0040
        # JOY_DATA: "no device" response byte
        0xFF
      when 0x0800..0x0803
        @cdrom ? @cdrom.read8(offset - 0x0800) : 0
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
      when 0x0040
        # JOY_DATA: "no device" response (16-bit read)
        0xFF
      when 0x0044
        # JOY_STAT (SIO0): TX Ready 1+2 + RX FIFO Not Empty set so the BIOS
        # progresses through TX/RX polls without deadlocking. /ACK signaling
        # and proper IRQ_SIO timing are not modeled, so SIO probing won't
        # actually time out -- BIOS will display the license screen but
        # continue probing controllers forever after that.
        0x07
      when 0x0048
        # JOY_MODE - readable, return 0
        0
      when 0x004A
        # JOY_CTRL - readable, return 0
        0
      when 0x005A
        # SIO1 CTRL
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
      when 0x0040
        # JOY_DATA (32-bit read) - no device
        0xFF
      when 0x0044
        # JOY_STAT (32-bit) - TX ready + RX FIFO not empty + /ACK high (no dev)
        0x87
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
      when 0x0800..0x0803
        @cdrom&.write8(offset - 0x0800, value)
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
