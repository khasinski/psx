# frozen_string_literal: true

module PSX
  class BIOS
    SIZE = 512 * 1024  # 512 KB

    def initialize(path)
      @data = File.binread(path)

      if @data.bytesize != SIZE
        raise ArgumentError, "Invalid BIOS size: expected #{SIZE} bytes, got #{@data.bytesize}"
      end
    end

    def read8(offset)
      @data.getbyte(offset)
    end

    def read16(offset)
      @data.byteslice(offset, 2).unpack1("v")
    end

    def read32(offset)
      @data.byteslice(offset, 4).unpack1("V")
    end
  end
end
