# frozen_string_literal: true

module PSX
  class BIOS
    SIZE = 512 * 1024  # 512 KB

    def initialize(path)
      @data = File.binread(path)

      if @data.bytesize != SIZE
        raise ArgumentError, "Invalid BIOS size: expected #{SIZE} bytes, got #{@data.bytesize}"
      end

      # Pre-compute 32-bit word array for fast read32 access
      # This trades memory for speed (512KB -> 512KB + 128K integers)
      @words = Array.new(SIZE / 4) do |i|
        offset = i * 4
        @data.getbyte(offset) |
          (@data.getbyte(offset + 1) << 8) |
          (@data.getbyte(offset + 2) << 16) |
          (@data.getbyte(offset + 3) << 24)
      end
    end

    def read8(offset)
      @data.getbyte(offset)
    end

    def read16(offset)
      @data.getbyte(offset) | (@data.getbyte(offset + 1) << 8)
    end

    def read32(offset)
      # Fast path: aligned access from pre-computed array
      if (offset & 3) == 0
        @words[offset >> 2]
      else
        # Unaligned access (rare)
        @data.getbyte(offset) |
          (@data.getbyte(offset + 1) << 8) |
          (@data.getbyte(offset + 2) << 16) |
          (@data.getbyte(offset + 3) << 24)
      end
    end
  end
end
