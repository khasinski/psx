# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

class DiscSpec < Minitest::Test
  SECTOR_SIZE = 2352

  # Build a small in-memory disc image: N sectors, each filled with a known
  # 2048-byte payload, wrapped in MODE2/2352 framing. Returns the .bin path.
  def make_bin(dir, payloads)
    bin_path = File.join(dir, "test.bin")
    File.open(bin_path, "wb") do |f|
      payloads.each_with_index do |p, lba|
        raise "payload must be 2048 bytes" if p.bytesize != 2048
        abs = lba + 150
        m, s, fr = abs / 4500, (abs / 75) % 60, abs % 75
        sync = "\x00\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00".b
        msf  = [(m / 10) << 4 | (m % 10), (s / 10) << 4 | (s % 10), (fr / 10) << 4 | (fr % 10)].pack("C*")
        sub  = "\x00\x00\x08\x00\x00\x00\x08\x00".b
        ecc  = "\x00" * 280
        f.write(sync + msf + "\x02".b + sub + p + ecc)
      end
    end
    bin_path
  end

  def test_msf_to_lba_and_back
    assert_equal 0, PSX::Disc.msf_to_lba(0, 2, 0)
    assert_equal 75, PSX::Disc.msf_to_lba(0, 3, 0)
    assert_equal [0, 2, 0], PSX::Disc.lba_to_msf(0)
    assert_equal [1, 0, 0], PSX::Disc.lba_to_msf(4350)  # 1 min - 2 sec = LBA 4350
    assert_equal 4350, PSX::Disc.msf_to_lba(1, 0, 0)
  end

  def test_bcd_helpers
    assert_equal 0x42, PSX::Disc.to_bcd(42)
    assert_equal 0x00, PSX::Disc.to_bcd(0)
    assert_equal 42, PSX::Disc.from_bcd(0x42)
    (0..99).each { |n| assert_equal n, PSX::Disc.from_bcd(PSX::Disc.to_bcd(n)) }
  end

  def test_bare_bin_single_track
    Dir.mktmpdir do |dir|
      payloads = [("A" * 2048).b, ("B" * 2048).b, ("C" * 2048).b]
      bin = make_bin(dir, payloads)
      disc = PSX::Disc.open(bin)

      assert_equal 1, disc.track_count
      assert_equal 3, disc.total_sectors

      assert_equal payloads[0], disc.read_data(0)
      assert_equal payloads[1], disc.read_data(1)
      assert_equal payloads[2], disc.read_data(2)

      raw = disc.read_sector(1)
      assert_equal SECTOR_SIZE, raw.bytesize
      assert_equal payloads[1], raw.byteslice(24, 2048) # mode-2 user data offset

      disc.close
    end
  end

  def test_cue_with_single_track
    Dir.mktmpdir do |dir|
      payloads = Array.new(5) { |i| (i.to_s * 2048).byteslice(0, 2048).b }
      payloads.map! { |p| p + ("\x00" * (2048 - p.bytesize)).b }
      bin = make_bin(dir, payloads)
      cue = File.join(dir, "test.cue")
      File.write(cue, <<~CUE)
        FILE "test.bin" BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00
      CUE

      disc = PSX::Disc.open(cue)
      assert_equal 1, disc.track_count
      assert_equal 5, disc.total_sectors
      assert_equal payloads[4], disc.read_data(4)
      disc.close
    end
  end

  def test_read_data_rejects_audio_track
    Dir.mktmpdir do |dir|
      bin = make_bin(dir, [("\x00" * 2048).b])
      cue = File.join(dir, "test.cue")
      File.write(cue, <<~CUE)
        FILE "test.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
      CUE
      disc = PSX::Disc.open(cue)
      assert_raises(RuntimeError) { disc.read_data(0) }
      disc.close
    end
  end

  # whole_sector mode returns 2340 bytes starting at offset 12 of the raw
  # sector: the 4-byte header (MSF + mode) + 8-byte sub-header + 2048
  # user data + 280 ECC. Games that stream CD-XA (FMV, in-game music)
  # need the sub-header to filter which channel they want.
  def test_read_whole_sector_returns_header_then_user_data
    Dir.mktmpdir do |dir|
      payload = ("USER" + ("\x00" * 2044)).b
      bin = make_bin(dir, [payload])
      disc = PSX::Disc.open(bin)

      whole = disc.read_whole_sector(0)
      assert_equal 2340, whole.bytesize, "whole sector slice is sync-stripped 2340 bytes"
      # First 4 bytes = MSF + mode. LBA 0 -> MSF 00:02:00 (75-frame offset),
      # mode byte = 0x02 for MODE2.
      assert_equal "\x00\x02\x00\x02".b, whole.byteslice(0, 4)
      # Next 8 bytes = the CD-XA sub-header make_bin baked in.
      assert_equal "\x00\x00\x08\x00\x00\x00\x08\x00".b, whole.byteslice(4, 8)
      # User data starts at offset 12.
      assert_equal "USER".b, whole.byteslice(12, 4)
      disc.close
    end
  end

  def test_track_for_lba_out_of_range
    Dir.mktmpdir do |dir|
      bin = make_bin(dir, [("\x00" * 2048).b, ("\x00" * 2048).b])
      disc = PSX::Disc.open(bin)
      refute_nil disc.track_for_lba(0)
      refute_nil disc.track_for_lba(1)
      assert_nil disc.track_for_lba(2)
      assert_nil disc.track_for_lba(-1)
      disc.close
    end
  end

  def test_region_code_detects_pal_license_string
    Dir.mktmpdir do |dir|
      payloads = Array.new(5) { ("\x00" * 2048).b }
      bin = make_bin(dir, payloads)
      File.open(bin, "r+b") do |f|
        f.seek(4 * SECTOR_SIZE)
        f.write("          Licensed  by          Sony Computer Entertainment Euro pe")
      end

      disc = PSX::Disc.open(bin)
      assert_equal :pal, disc.region_code
      disc.close
    end
  end
end
