# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

# End-to-end integration: build a synthetic CD image from a known PS-EXE,
# boot it via fast-boot, and verify the EXE's TTY output matches the
# reference psx.log.
#
# Skips when the SCPH1001 BIOS, mkisofs, or the ps1-tests checkout isn't
# present — these aren't checked in, so CI runs won't have them either.
class CDBootSpec < Minitest::Test
  BIOS    = File.expand_path("../SCPH1001.BIN", __dir__)
  PSX_EXE = File.expand_path("../.tests/cpu/cop/cop.exe", __dir__)
  PSX_LOG = File.expand_path("../.tests/cpu/cop/psx.log", __dir__)

  def setup
    skip "BIOS not present"        unless File.exist?(BIOS)
    skip "test PS-EXE not present" unless File.exist?(PSX_EXE)
    skip "mkisofs not installed"   unless system("which mkisofs > /dev/null 2>&1")
  end

  def build_disc(dir)
    stage = File.join(dir, "stage")
    Dir.mkdir(stage)
    File.write(File.join(stage, "SYSTEM.CNF"), <<~CNF)
      BOOT=cdrom:\\PSX.EXE;1
      TCB=4
      EVENT=10
      STACK=801FFFF0
    CNF
    require "fileutils"
    FileUtils.cp(PSX_EXE, File.join(stage, "PSX.EXE"))
    iso = File.join(dir, "test.iso")
    system("mkisofs", "-quiet", "-iso-level", "1", "-V", "PSXTEST", "-no-pad",
           "-o", iso, stage, out: File::NULL, err: File::NULL) or raise "mkisofs failed"
    bin = File.join(dir, "test.bin")
    cue = File.join(dir, "test.cue")
    cooked = File.binread(iso)
    File.open(bin, "wb") do |f|
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
    File.write(cue, "FILE \"test.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n")
    cue
  end

  def test_fast_boot_loads_and_runs_ps_exe
    Dir.mktmpdir do |dir|
      cue = build_disc(dir)

      RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)
      emu = PSX::Emulator.new(BIOS, disc_path: cue)
      captured = String.new
      emu.cpu.tty_handler = ->(kind, val) do
        case kind
        when :char then captured << val.chr
        when :str  then captured << val
        end
      end

      emu.fast_boot_from_disc
      # Generous cap — cpu/cop completes in ~30M cycles in practice.
      remaining = 50_000_000
      step = 500_000
      until captured.include?("Done.") || remaining <= 0
        emu.run(steps: step)
        remaining -= step
      end

      assert_includes captured, "cpu/cop", "EXE should print its test-suite header"
      assert_includes captured, "Done.",   "EXE should reach end-of-test marker"

      # Same superset-pass check psx-test does: count passes/fails in both.
      passes = captured.scan(/^pass - /).size
      fails  = captured.scan(/^fail - /).size
      ref_passes = File.read(PSX_LOG).scan(/^% pass - /).size
      assert_equal 0, fails, "no test should fail"
      assert passes >= ref_passes, "expected at least #{ref_passes} passes, got #{passes}"
    end
  end
end
