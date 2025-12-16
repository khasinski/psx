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
      @data.byteslice(offset & MASK, 2).unpack1("v")
    end

    def read32(offset)
      @data.byteslice(offset & MASK, 4).unpack1("V")
    end

    def write8(offset, value)
      @data.setbyte(offset & MASK, value & 0xFF)
    end

    def write16(offset, value)
      offset &= MASK
      @data[offset, 2] = [value].pack("v")
    end

    def write32(offset, value)
      offset &= MASK
      @data[offset, 4] = [value].pack("V")
    end
  end
end
