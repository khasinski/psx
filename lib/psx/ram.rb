# frozen_string_literal: true

module PSX
  class RAM
    SIZE = 2 * 1024 * 1024  # 2 MB
    MASK = SIZE - 1

    def initialize
      @data = ("\x00" * SIZE).b  # Force binary encoding
    end

    def read8(offset)
      @data.getbyte(offset & MASK)
    end

    def read16(offset)
      offset &= MASK
      @data.getbyte(offset) | (@data.getbyte(offset + 1) << 8)
    end

    def read32(offset)
      offset &= MASK
      @data.getbyte(offset) |
        (@data.getbyte(offset + 1) << 8) |
        (@data.getbyte(offset + 2) << 16) |
        (@data.getbyte(offset + 3) << 24)
    end

    def write8(offset, value)
      @data.setbyte(offset & MASK, value & 0xFF)
    end

    def write16(offset, value)
      offset &= MASK
      @data.setbyte(offset, value & 0xFF)
      @data.setbyte(offset + 1, (value >> 8) & 0xFF)
    end

    def write32(offset, value)
      offset &= MASK
      @data.setbyte(offset, value & 0xFF)
      @data.setbyte(offset + 1, (value >> 8) & 0xFF)
      @data.setbyte(offset + 2, (value >> 16) & 0xFF)
      @data.setbyte(offset + 3, (value >> 24) & 0xFF)
    end
  end
end
