# frozen_string_literal: true

module PSX
  # Disc image loader (.bin / .cue).
  #
  # Supports the format virtually every PSX dump uses: a single .bin file of
  # raw 2352-byte sectors, optionally described by a .cue sheet with one or
  # more tracks. Multi-track support is here so audio tracks at the end of a
  # mixed-mode CD don't break us, but only data tracks (MODE1/MODE2) are
  # actually readable for now.
  #
  # The unit we work in everywhere downstream is "absolute LBA": sector
  # index counting from MSF 00:02:00 (the 150-frame pre-gap). MSF↔LBA helpers
  # live as module functions.
  class Disc
    SECTOR_SIZE = 2352
    PREGAP_FRAMES = 150
    FRAMES_PER_SEC = 75
    SECS_PER_MIN = 60

    Track = Struct.new(:number, :mode, :sector_size, :file, :file_lba_start,
                       :lba_start, :lba_length, keyword_init: true) do
      def audio? = mode == :audio
      def data?  = !audio?
      # End-of-track LBA (one past the last sector of this track).
      def lba_end = lba_start + lba_length
    end

    attr_reader :tracks, :total_sectors

    def self.open(path)
      ext = File.extname(path).downcase
      case ext
      when ".cue" then from_cue(path)
      when ".bin", ".iso", ".img" then from_bin(path)
      else
        raise ArgumentError, "unsupported disc image extension #{ext.inspect}"
      end
    end

    # Load a bare .bin file: assume MODE2/2352, single data track.
    def self.from_bin(path)
      size = File.size(path)
      raise ArgumentError, "#{path} is not a multiple of #{SECTOR_SIZE} bytes" if size % SECTOR_SIZE != 0
      sector_count = size / SECTOR_SIZE
      io = File.open(path, "rb")
      track = Track.new(
        number: 1, mode: :mode2, sector_size: SECTOR_SIZE,
        file: io, file_lba_start: 0,
        lba_start: 0, lba_length: sector_count
      )
      new([track])
    end

    # Parse a minimal .cue sheet and open the referenced .bin(s).
    def self.from_cue(path)
      dir = File.dirname(path)
      lines = File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)

      current_file = nil       # currently active FILE handle + path
      current_file_lba = 0     # cumulative LBA of the FILE's start
      tracks = []
      track_files = []         # parallel to tracks: { io:, lba_start:, length: }
      pending_track = nil
      pending_indexes = nil

      flush = lambda do
        next unless pending_track
        # Index 01 marks the actual track start.
        idx01 = pending_indexes[1]
        raise "track #{pending_track[:number]} missing INDEX 01" unless idx01
        file_lba = current_file_lba + idx01
        pending_track[:file_lba_start] = current_file[:lba_start_in_file]
        pending_track[:lba_start] = file_lba
        pending_track[:file] = current_file[:io]
        tracks << Track.new(**pending_track, lba_length: 0) # length filled in below
        track_files << {
          io: current_file[:io],
          lba_start: current_file_lba,
          length: current_file[:length_in_lba]
        }
        pending_track = nil
        pending_indexes = nil
      end

      lines.each do |line|
        case line
        when /^FILE\s+"([^"]+)"\s+BINARY$/i, /^FILE\s+(\S+)\s+BINARY$/i
          flush.call
          # Switch to a new bin file. Track LBA continues across files.
          if current_file && pending_track.nil?
            current_file_lba += current_file[:length_in_lba]
          end
          name = $1
          bin_path = File.expand_path(name, dir)
          io = File.open(bin_path, "rb")
          length = io.size / SECTOR_SIZE
          current_file = { path: bin_path, io: io, length_in_lba: length, lba_start_in_file: 0 }
        when /^\s*TRACK\s+(\d+)\s+(\S+)$/i
          flush.call
          number = Integer($1, 10)
          mode = decode_mode($2)
          raise "TRACK before FILE in cue at #{line.inspect}" unless current_file
          pending_track = { number: number, mode: mode, sector_size: SECTOR_SIZE }
          pending_indexes = {}
        when /^\s*INDEX\s+(\d+)\s+(\d+):(\d+):(\d+)$/i
          idx = Integer($1, 10)
          m, s, f = Integer($2, 10), Integer($3, 10), Integer($4, 10)
          frames = (m * SECS_PER_MIN + s) * FRAMES_PER_SEC + f
          pending_indexes[idx] = frames
        # PREGAP / POSTGAP / REM / CATALOG / PERFORMER / TITLE: ignored.
        end
      end
      flush.call

      # Fill in lba_length: each track ends at the next track's start within
      # the same FILE, or at the end of its own FILE if it's the last track
      # in that FILE. (Important for multi-bin cues like Ridge Racer where
      # every track has its own .bin — without this, every track inherits
      # the LAST file's end and they all overlap.)
      tracks.each_with_index do |t, i|
        next_t = tracks[i + 1]
        if next_t && next_t.file == t.file
          t.lba_length = next_t.lba_start - t.lba_start
        else
          tf = track_files[i]
          file_lba_end = tf[:lba_start] + tf[:length]
          t.lba_length = file_lba_end - t.lba_start
        end
      end

      raise "cue contains no tracks: #{path}" if tracks.empty?
      new(tracks)
    end

    def self.decode_mode(s)
      case s.upcase
      when "AUDIO" then :audio
      when /^MODE1\/?/ then :mode1
      when /^MODE2\/?/ then :mode2
      else
        raise ArgumentError, "unrecognized track mode #{s.inspect}"
      end
    end

    def initialize(tracks)
      @tracks = tracks
      @total_sectors = tracks.map(&:lba_end).max
      @region_code = nil
    end

    def region_code
      @region_code ||= detect_region_code
    end

    def track_count
      @tracks.size
    end

    # Find which track an absolute LBA falls in. Returns the Track or nil if
    # out of range.
    def track_for_lba(lba)
      @tracks.find { |t| lba >= t.lba_start && lba < t.lba_end }
    end

    # Read the raw 2352-byte sector at absolute LBA. Returns a binary
    # String. Raises if LBA is out of range or on an audio track (audio
    # data isn't usable as program data).
    def read_sector(lba)
      track = track_for_lba(lba)
      raise "no track contains LBA #{lba}" unless track
      raise "LBA #{lba} is on audio track #{track.number}" if track.audio?

      file_lba = track.file_lba_start + (lba - track.lba_start)
      offset = file_lba * track.sector_size
      track.file.seek(offset)
      data = track.file.read(track.sector_size)
      raise "short sector at LBA #{lba}" unless data && data.bytesize == track.sector_size
      data
    end

    # Read the raw 2352 bytes of an AUDIO sector at the given LBA. Format
    # is interleaved 16-bit signed stereo at 44.1 kHz — exactly the SDL
    # AUDIO_S16LSB byte stream we feed into the host audio queue, no
    # conversion needed.
    #
    # Returns 2352 zero bytes (silence) for LBAs that fall in a pregap
    # between two audio tracks — real CD hardware plays silence through
    # those gaps rather than stopping. Returns nil only when the LBA is
    # past the last track on the disc, or on a data track.
    SILENT_SECTOR = ("\x00" * 2352).b.freeze
    def read_audio_sector(lba)
      track = track_for_lba(lba)
      if track.nil?
        # Could be a between-track pregap or off the disc. Distinguish.
        return nil if lba >= total_sectors
        return SILENT_SECTOR
      end
      return nil unless track.audio?

      file_lba = track.file_lba_start + (lba - track.lba_start)
      offset = file_lba * track.sector_size
      track.file.seek(offset)
      data = track.file.read(track.sector_size)
      return nil unless data && data.bytesize == track.sector_size
      data
    end

    # 2340-byte "whole sector" slice — what the CD-ROM controller returns
    # when SetMode bit 5 (whole_sector) is set. Skips the 12 sync bytes
    # but keeps everything from offset 12 onwards: 4-byte header (MSF +
    # mode), 8-byte sub-header (CD-XA file/channel/submode/coding info,
    # repeated), 2048-byte user data, and the trailing EDC/ECC. Games
    # that stream CD-XA (FMV, in-game music) toggle this mode and read
    # the sub-header first to filter which channel they want.
    def read_whole_sector(lba)
      raw = read_sector(lba)
      case raw.bytesize
      when 2048
        # Cooked ISO: no sync/header/sub-header on disc. Fabricate a
        # zero header so reads of the sub-header area don't return
        # arbitrary user-data bytes.
        ("\x00" * 12).b + raw + ("\x00" * 280).b
      when 2336 then ("\x00" * 4).b + raw         # MODE2/2336: prepend header
      when 2352 then raw.byteslice(12, 2340)      # skip sync; keep the rest
      else
        raise "unsupported sector size #{raw.bytesize} for whole_sector"
      end
    end

    # 2048-byte user-data slice of a sector. For MODE2/2352 (the default)
    # the layout is:
    #   [12 sync][3 header MSF][1 mode][8 sub-header][2048 user][280 ECC]
    # so user data starts at offset 24. For MODE1/2352 it's 12+3+1 = 16.
    # For 2048-byte sectors (cooked ISO) the whole sector is user data.
    def read_data(lba)
      raw = read_sector(lba)
      case raw.bytesize
      when 2048 then raw
      when 2336 then raw.byteslice(8, 2048) # MODE2/2336 = sub-header + user
      when 2352
        # Sniff mode byte at offset 15 to distinguish MODE1 vs MODE2.
        mode_byte = raw.getbyte(15)
        if mode_byte == 2
          raw.byteslice(24, 2048)
        else
          raw.byteslice(16, 2048)
        end
      else
        raise "unsupported sector size #{raw.bytesize}"
      end
    end

    def close
      @tracks.map(&:file).uniq.each { |io| io.close rescue nil }
    end

    # --- MSF helpers ---------------------------------------------------------

    def self.msf_to_lba(m, s, f)
      ((m * SECS_PER_MIN + s) * FRAMES_PER_SEC + f) - PREGAP_FRAMES
    end

    def self.lba_to_msf(lba)
      total = lba + PREGAP_FRAMES
      m = total / (SECS_PER_MIN * FRAMES_PER_SEC)
      s = (total / FRAMES_PER_SEC) % SECS_PER_MIN
      f = total % FRAMES_PER_SEC
      [m, s, f]
    end

    # BCD helpers — PSX CDROM reports MSF in BCD bytes over the response FIFO.
    def self.to_bcd(n)
      ((n / 10) << 4) | (n % 10)
    end

    def self.from_bcd(byte)
      ((byte >> 4) * 10) + (byte & 0x0F)
    end

    private

    def detect_region_code
      region_from_system_area || region_from_boot_serial || :ntsc_u
    end

    def region_from_system_area
      raw = read_sector(4)
      return :ntsc_u if raw.include?("Sony Computer Entertainment Amer  ica")
      return :ntsc_j if raw.include?("Sony Computer Entertainment Inc.")
      return :pal if raw.include?("Sony Computer Entertainment Euro pe")

      nil
    rescue StandardError
      nil
    end

    def region_from_boot_serial
      return nil unless defined?(ISO9660)

      cnf = ISO9660.new(self).read_file("SYSTEM.CNF")
      boot = cnf[/^BOOT\s*=\s*(.+?)(?:;\d+)?\s*$/i, 1]
      return nil unless boot

      serial = File.basename(boot.strip.sub(/\Acdrom:[\\\/]*/i, "")).downcase
      return :pal if serial.start_with?("sces", "sced", "sles", "sled")
      return :ntsc_j if serial.start_with?("scps", "slps", "slpm", "sczs", "papx")
      return :ntsc_u if serial.start_with?("scus", "slus")

      nil
    rescue StandardError
      nil
    end
  end
end
