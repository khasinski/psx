# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

class ISO9660Spec < Minitest::Test
  # End-to-end-ish: ask `mkisofs` to lay out a real ISO with known files,
  # then read it back through our Disc + ISO9660 stack. Skipped when
  # mkisofs is not installed.
  def setup
    skip "mkisofs not installed" unless system("which mkisofs > /dev/null 2>&1")
  end

  def with_iso_disc
    Dir.mktmpdir do |dir|
      stage = File.join(dir, "stage")
      Dir.mkdir(stage)
      File.write(File.join(stage, "HELLO.TXT"), "hello iso\n")
      File.write(File.join(stage, "BOOT.INF"), "answer=42\n")
      iso = File.join(dir, "out.iso")
      system("mkisofs", "-quiet", "-iso-level", "1", "-V", "TEST", "-o", iso, stage,
             out: File::NULL, err: File::NULL) or
        raise "mkisofs failed"
      bin = File.join(dir, "out.bin")
      wrap_mode2(iso, bin)
      disc = PSX::Disc.open(bin)
      yield disc
    ensure
      disc&.close
    end
  end

  def wrap_mode2(iso_path, bin_path)
    cooked = File.binread(iso_path)
    File.open(bin_path, "wb") do |f|
      (cooked.bytesize / 2048).times do |lba|
        payload = cooked.byteslice(lba * 2048, 2048)
        abs = lba + 150
        m, s, fr = abs / 4500, (abs / 75) % 60, abs % 75
        sync = "\x00\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00".b
        msf  = [(m / 10) << 4 | (m % 10), (s / 10) << 4 | (s % 10), (fr / 10) << 4 | (fr % 10)].pack("C*")
        sub  = "\x00\x00\x08\x00\x00\x00\x08\x00".b
        ecc  = "\x00" * 280
        f.write(sync + msf + "\x02".b + sub + payload + ecc)
      end
    end
  end

  def test_lists_root_files
    with_iso_disc do |disc|
      iso = PSX::ISO9660.new(disc)
      names = iso.list_root.sort
      assert_includes names, "BOOT.INF"
      assert_includes names, "HELLO.TXT"
    end
  end

  def test_reads_file_contents
    with_iso_disc do |disc|
      iso = PSX::ISO9660.new(disc)
      assert_equal "hello iso\n", iso.read_file("HELLO.TXT")
      assert_equal "answer=42\n", iso.read_file("BOOT.INF")
    end
  end

  def test_raises_on_missing_file
    with_iso_disc do |disc|
      iso = PSX::ISO9660.new(disc)
      assert_raises(RuntimeError) { iso.read_file("MISSING.TXT") }
    end
  end
end
