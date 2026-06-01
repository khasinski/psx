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

    attr_accessor :cache_isolated, :dma, :gpu, :cdrom, :sio0, :spu, :mdec
    attr_reader :ram_words, :bios_words, :isolated_cache_words  # exposed so CPU can inline read32/fetch32 fast paths

    def initialize(bios:, ram:, interrupts: nil, dma: nil, timers: nil, cdrom: nil, sio0: nil, spu: nil, mdec: nil)
      @bios = bios
      @ram = ram
      @ram_words = ram.instance_variable_get(:@words)  # for inlined fast-path
      @bios_words = bios.instance_variable_get(:@words)
      @interrupts = interrupts
      @dma = dma
      @timers = timers
      @cdrom = cdrom
      @sio0 = sio0
      @spu = spu
      @mdec = mdec
      @gpu = nil  # Set later when GPU is created
      @scratchpad = ("\x00" * SCRATCHPAD_SIZE).b  # Force binary encoding
      @cache_isolated = false
      @isolated_cache_words = {}
    end

    def tick_dma
      @dma&.tick(self, gpu: @gpu)
    end

    # Whether instruction fetch is permitted at this virtual address. Real
    # hardware raises a bus-error exception on instruction fetch from most
    # I/O ranges and from the scratchpad (which lives where the data cache
    # would be on a normal MIPS chip). A handful of IO regions do respond
    # to 32-bit reads (DMA, SPU, GPU); fetch from those returns garbage but
    # doesn't trap.
    #
    # Match the expectations of ps1-tests cpu/code-in-io:
    #   scratchpad / IRQ / MDEC / Timers / SIO -> bus error
    #   DMA / SPU / GPU register space         -> no exception
    def fetchable?(addr)
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]
      return true if phys < 0x0080_0000                              # RAM
      return true if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000       # BIOS
      if phys >= 0x1F80_1000 && phys < 0x1F80_3000
        # Specific IO sub-ranges that DO respond to instruction fetch.
        return true if phys >= 0x1F80_1080 && phys < 0x1F80_1100      # DMA
        return true if phys >= 0x1F80_1810 && phys < 0x1F80_1820      # GPU
        return true if phys >= 0x1F80_1C00 && phys < 0x1F80_2000      # SPU
        return false                                                  # IRQ/MDEC/Timer/SIO/etc
      end
      false                                                          # Scratchpad, expansion, cache control
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

    # Fused instruction fetch: tests fetchable? + reads in one call. Returns
    # the 32-bit instruction word, or nil if PC is in a region the bus
    # doesn't service (the caller raises a bus-error exception). Used by
    # the cpu.step hot path so we save a method dispatch per CPU step.
    def fetch32(addr)
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]
      if phys < 0x0080_0000
        index = (phys & RAM_MIRROR_MASK) >> 2
        ram_word = @ram_words[index]
        return ram_word unless ram_word.zero?
        return @isolated_cache_words.fetch(index) { ram_word }
      end
      return @bios_words[(phys - BIOS_START) >> 2] if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
      # Rare paths: IO/DMA/GPU/SPU/SBUS regions that DO respond to fetch.
      if phys >= 0x1F80_1000 && phys < 0x1F80_3000
        return io_read32(phys - IO_START) if (phys >= 0x1F80_1080 && phys < 0x1F80_1100) ||
                                              (phys >= 0x1F80_1810 && phys < 0x1F80_1820) ||
                                              (phys >= 0x1F80_1C00 && phys < 0x1F80_2000)
      end
      nil  # bus error — instruction fetch from a forbidden region
    end

    def read32(addr)
      # Fast path: translate virtual to physical
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      # Inlined RAM fast path (the overwhelmingly most common case for
      # instruction fetch + lw + linked-list DMA).
      if phys < 0x0080_0000
        return @ram_words[(phys & RAM_MIRROR_MASK) >> 2]
      end

      # Inlined BIOS fast path — same idea, instruction fetch out of ROM
      # happens during every kernel call.
      if phys >= 0x1FC0_0000 && phys < 0x1FC8_0000
        return @bios_words[(phys - BIOS_START) >> 2]
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

      # PSX RAM chip is 2 MB but the address decoder uses an 8 MB window;
      # bits 0..20 are the only ones routed to the chip, so every store
      # within the 8 MB region commits to the same 2 MB cell (symmetric
      # mirror, matches real hardware).
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

      # RAM (see write8 note on symmetric mirror behaviour).
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
      # Fast path: translate virtual to physical
      phys = addr & REGION_MASK[(addr >> 29) & 0x7]

      if @cache_isolated
        if phys < 0x0080_0000 && (phys & 3).zero?
          @isolated_cache_words[(phys & RAM_MIRROR_MASK) >> 2] = value & 0xFFFF_FFFF
        end
        return
      end

      # Inlined RAM fast path (see write8 note on symmetric mirror).
      if phys < 0x0080_0000
        @ram_words[(phys & RAM_MIRROR_MASK) >> 2] = value & 0xFFFF_FFFF
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

      # Hot I/O path: DMA channel registers. Ridge streams GP0 lists through
      # GPU linked-list DMA, so avoid the full I/O decoder on every CHCR write.
      if phys >= 0x1F80_1080 && phys < 0x1F80_10F0
        @dma&.write(phys - 0x1F80_1080, value)
        tick_dma
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
      when 0x0040..0x004F
        @sio0 ? @sio0.read8(offset) : 0xFF
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
      when 0x0040..0x004F
        @sio0 ? @sio0.read16(offset) : 0
      when 0x005A
        # SIO1 CTRL
        0
      when 0x0070
        # I_STAT (low halfword) — BIOS uses 16-bit access.
        (@interrupts&.read_stat || 0) & 0xFFFF
      when 0x0074
        # I_MASK (low halfword) — BIOS uses 16-bit access.
        (@interrupts&.read_mask || 0) & 0xFFFF
      when 0x0100...0x0130
        @timers&.read(offset - 0x0100) || 0
      when 0x0C80...0x0D00
        # SPU voice registers - read back 0
        0
      when 0x0D80...0x0E00
        @spu ? @spu.read16(offset) : 0
      else
        # warn format("IO read16 at 0x%08X", IO_START + offset)
        0
      end
    end

    def io_read32(offset)
      if offset >= 0x0000 && offset < 0x0024
        # Memory control 1
        0
      elsif offset >= 0x0040 && offset <= 0x004F
        @sio0 ? @sio0.read32(offset) : 0
      elsif offset == 0x0060
        # RAM size register
        0x0000_0B88
      elsif offset == 0x0070
        # I_STAT - Interrupt status
        @interrupts&.read_stat || 0
      elsif offset == 0x0074
        # I_MASK - Interrupt mask
        @interrupts&.read_mask || 0
      elsif offset >= 0x0080 && offset < 0x00F0
        # DMA channel registers
        @dma&.read(offset - 0x0080) || 0
      elsif offset == 0x00F0
        # DMA DPCR - control
        @dma&.dpcr || 0x0765_4321
      elsif offset == 0x00F4
        # DMA DICR - interrupt control
        @dma&.dicr || 0
      elsif offset >= 0x0100 && offset < 0x0130
        # Timers
        @timers&.read(offset - 0x0100) || 0
      elsif offset == 0x0810
        # GPU GPUREAD
        @gpu&.read_data || 0
      elsif offset == 0x0814
        # GPU GPUSTAT - return ready, display enabled
        @gpu&.status || 0x1C00_0000
      elsif offset == 0x0820
        # MDEC0: decoded output data (FIFO drain)
        @mdec&.read32_data || 0
      elsif offset == 0x0824
        # MDEC1: status word. Nil-MDEC fallback returns "output FIFO
        # empty" — any reasonable poll loop sees "no data" and gives up.
        @mdec&.read32_status || 0x8000_0000
      elsif offset >= 0x0C00 && offset < 0x1000
        # SPU register window. Real hardware reads back the most recent
        # 32-bit value; our SPU stub keeps a shadow so writes survive.
        # ps1-tests cpu/code-in-io's testCodeInSPU relies on this so the
        # `jr ra` instruction it writes into voice 0 reads back via fetch.
        if @spu
          lo = @spu.read16(offset)
          hi = @spu.read16(offset + 2)
          (hi << 16) | lo
        else
          0
        end
      else
        # warn format("IO read32 at 0x%08X", IO_START + offset)
        0
      end
    end

    def io_write8(offset, value)
      case offset
      when 0x0040..0x004F
        @sio0&.write8(offset, value)
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
      when 0x0040..0x004F
        @sio0&.write16(offset, value)
      when 0x0070
        # I_STAT ack via 16-bit write: the BIOS ack writes the low halfword.
        # Preserve the upper bits of stat (real I_STAT is 11 bits anyway).
        if @interrupts
          high = @interrupts.stat & ~0xFFFF
          @interrupts.write_stat((value & 0xFFFF) | high)
        end
      when 0x0074
        # I_MASK via 16-bit write — BIOS uses this in SetIntMask.
        @interrupts&.write_mask(value & 0xFFFF)
      when 0x0100...0x0130
        @timers&.write(offset - 0x0100, value)
      when 0x0C80...0x0D80
        # SPU voice registers - drop
      when 0x0D80...0x0E00
        @spu&.write16(offset, value)
      else
        # warn format("IO write16 at 0x%08X = 0x%04X", IO_START + offset, value)
      end
    end

    def io_write32(offset, value)
      if offset >= 0x0000 && offset < 0x0024
        # Memory control 1 - ignore for now
      elsif offset >= 0x0040 && offset <= 0x004F
        @sio0&.write32(offset, value)
      elsif offset == 0x0060
        # RAM size config - ignore
      elsif offset == 0x0070
        # I_STAT - Interrupt status (write acknowledges)
        @interrupts&.write_stat(value)
      elsif offset == 0x0074
        # I_MASK - Interrupt mask
        @interrupts&.write_mask(value)
      elsif offset >= 0x0080 && offset < 0x00F0
        # DMA channel registers
        @dma&.write(offset - 0x0080, value)
        # Check if this triggered a DMA transfer
        tick_dma
      elsif offset == 0x00F0
        # DMA DPCR
        @dma&.write(0x70, value)
      elsif offset == 0x00F4
        # DMA DICR
        @dma&.write(0x74, value)
      elsif offset >= 0x0100 && offset < 0x0130
        # Timers
        @timers&.write(offset - 0x0100, value)
      elsif offset == 0x0810
        # GPU GP0
        @gpu&.gp0(value)
      elsif offset == 0x0814
        # GPU GP1
        @gpu&.gp1(value)
      elsif offset == 0x0820
        # MDEC0: command / RLE data
        @mdec&.write32_data(value)
      elsif offset == 0x0824
        # MDEC1: control / reset
        @mdec&.write32_control(value)
      elsif offset >= 0x0C00 && offset < 0x1000
        # SPU register window. Treat 32-bit writes as two halfword writes
        # so the SPU stub's shadow stays in sync (see io_read32 for SPU).
        @spu&.write16(offset, value & 0xFFFF)
        @spu&.write16(offset + 2, (value >> 16) & 0xFFFF)
      else
        # warn format("IO write32 at 0x%08X = 0x%08X", IO_START + offset, value)
      end
    end
  end
end
