# frozen_string_literal: true

module PSX
  class BIOS
    SIZE = 512 * 1024  # 512 KB
    attr_reader :region_code

    # SHA1s of recognised BIOS images and the fast-boot patches we know for
    # them. Each patch is [byte_offset, 32-bit value]; the value is written
    # at load time, before the CPU ever fetches from the BIOS image. NOPping
    # specific `jal` instructions inside the splash function skips the
    # multi-second logo+license animation without touching the wait routine
    # itself (other BIOS code keeps its normal pacing).
    KNOWN_BIOSES = {
      # SCPH-1001 / DTLH-3000 — NTSC US, kernel "2.2 12/04/95 A"
      # Tried patching the shell's "wait N frames" helper at 0x41DA4 and
      # the splash-loop JALs that call it. Neither made the BIOS reach
      # "Execute !" sooner -- the kernel VSync routine has its own GPUSTAT
      # bit-31 busy-wait that dominates regardless. Left here as a hook
      # for a future iteration that finds the right offsets (e.g., the
      # splash function's top-level entry, or the vsync counter at
      # 0x80079D9C in RAM).
      "10155d8d6e6e832d6ea66db9bc098321fb5e8ebf" => {
        name: "SCPH-1001",
        region_code: :ntsc_u,
        fast_boot_patches: []
      }
    }.freeze

    def initialize(path, fast_boot: false)
      @data = File.binread(path)

      if @data.bytesize != SIZE
        raise ArgumentError, "Invalid BIOS size: expected #{SIZE} bytes, got #{@data.bytesize}"
      end

      require "digest"
      @sha1 = Digest::SHA1.hexdigest(@data)
      @region_code = KNOWN_BIOSES[@sha1]&.fetch(:region_code, nil)

      if fast_boot
        info = KNOWN_BIOSES[@sha1]
        if info
          info[:fast_boot_patches].each { |off, val| patch32!(off, val) }
        else
          warn "BIOS #{@sha1[0, 8]} not in fast-boot patch table; running unpatched"
        end
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

    def patch32!(offset, value)
      @data.setbyte(offset, value & 0xFF)
      @data.setbyte(offset + 1, (value >> 8) & 0xFF)
      @data.setbyte(offset + 2, (value >> 16) & 0xFF)
      @data.setbyte(offset + 3, (value >> 24) & 0xFF)
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
