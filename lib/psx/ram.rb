# frozen_string_literal: true

module PSX
  class RAM
    SIZE = 2 * 1024 * 1024  # 2 MB
    MASK = SIZE - 1
    WORD_MASK = (SIZE / 4) - 1

    # Words store RAM as 512K 32-bit ints. Array#[] / []= is faster than
    # four String#getbyte calls per access, and instruction fetch + lw +
    # sw account for the majority of memory traffic. read8/read16/write8/
    # write16 do partial-word RMW, which is rarer in practice and still
    # cheap (one Array access + bitops).
    def initialize
      @words = Array.new(SIZE / 4, 0)
    end

    def read32(offset)
      @words[(offset & MASK) >> 2]
    end

    def write32(offset, value)
      @words[(offset & MASK) >> 2] = value & 0xFFFF_FFFF
    end

    def read16(offset)
      offset &= MASK
      word = @words[offset >> 2]
      shift = (offset & 2) * 8
      (word >> shift) & 0xFFFF
    end

    def write16(offset, value)
      offset &= MASK
      idx = offset >> 2
      shift = (offset & 2) * 8
      mask = 0xFFFF << shift
      @words[idx] = ((@words[idx] & ~mask) | ((value & 0xFFFF) << shift)) & 0xFFFF_FFFF
    end

    def read8(offset)
      offset &= MASK
      word = @words[offset >> 2]
      shift = (offset & 3) * 8
      (word >> shift) & 0xFF
    end

    def write8(offset, value)
      offset &= MASK
      idx = offset >> 2
      shift = (offset & 3) * 8
      mask = 0xFF << shift
      @words[idx] = ((@words[idx] & ~mask) | ((value & 0xFF) << shift)) & 0xFFFF_FFFF
    end
  end
end
