# frozen_string_literal: true

module PSX
  # Minimal ISO9660 reader. Just enough to find a file by name in the root
  # directory and slurp its contents back from a Disc. Used by fast-boot to
  # locate SYSTEM.CNF and the PS-EXE on a disc image without going through
  # the BIOS shell.
  class ISO9660
    Entry = Struct.new(:name, :lba, :size, :directory?, keyword_init: true)

    def initialize(disc)
      @disc = disc
      @root = parse_root_directory
    end

    # Read the named file from the root directory. Path may be a single
    # component ("SYSTEM.CNF") or "FOO\\BAR.EXE" / "FOO/BAR.EXE" for
    # subdirectories. Returns the file contents as a binary string.
    def read_file(path)
      parts = path.tr("\\", "/").split("/").reject(&:empty?)
      entry = find_in(@root, parts.shift.upcase)
      raise "ISO9660: path not found: #{path}" unless entry

      until parts.empty?
        raise "ISO9660: not a directory: #{entry.name}" unless entry.directory?
        children = parse_directory(entry.lba, entry.size)
        entry = find_in(children, parts.shift.upcase)
        raise "ISO9660: path not found: #{path}" unless entry
      end

      raise "ISO9660: is a directory: #{path}" if entry.directory?
      read_contiguous(entry.lba, entry.size)
    end

    def list_root
      @root.map(&:name)
    end

    private

    def parse_root_directory
      pvd = @disc.read_data(16)
      raise "no PVD at sector 16" unless pvd.byteslice(0, 7) == "\x01CD001\x01".b
      # Root directory record lives at offset 156, 34 bytes long.
      root_record = pvd.byteslice(156, 34)
      root_lba  = root_record.byteslice(2, 4).unpack1("V")
      root_size = root_record.byteslice(10, 4).unpack1("V")
      parse_directory(root_lba, root_size)
    end

    def parse_directory(lba, size)
      raw = read_contiguous(lba, size)
      entries = []
      pos = 0
      while pos < raw.bytesize
        len = raw.getbyte(pos)
        if len.nil? || len.zero?
          # Padding to sector boundary.
          pos = ((pos / 2048) + 1) * 2048
          next
        end
        ext_attr_len = raw.getbyte(pos + 1)
        ent_lba = raw.byteslice(pos + 2, 4).unpack1("V")
        ent_size = raw.byteslice(pos + 10, 4).unpack1("V")
        flags = raw.getbyte(pos + 25)
        name_len = raw.getbyte(pos + 32)
        raw_name = raw.byteslice(pos + 33, name_len)
        # Skip "." (0x00) and ".." (0x01) entries.
        unless name_len == 1 && (raw_name == "\x00" || raw_name == "\x01")
          name = raw_name.dup.force_encoding(Encoding::ASCII_8BIT).sub(/;\d+\z/, "")
          entries << Entry.new(
            name: name,
            lba: ent_lba,
            size: ent_size,
            directory?: (flags & 0x02) != 0
          )
        end
        _ = ext_attr_len
        pos += len
      end
      entries
    end

    def find_in(entries, name)
      entries.find { |e| e.name.upcase == name }
    end

    def read_contiguous(start_lba, size)
      out = String.new(capacity: size)
      lba = start_lba
      remaining = size
      while remaining.positive?
        chunk = @disc.read_data(lba)
        take = [chunk.bytesize, remaining].min
        out << chunk.byteslice(0, take)
        remaining -= take
        lba += 1
      end
      out
    end
  end
end
