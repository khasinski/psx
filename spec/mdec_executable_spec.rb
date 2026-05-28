# frozen_string_literal: true

require_relative "spec_helper"

class MDECExecutableSpec < Minitest::Test
  BIOS = File.expand_path("../SCPH1001.BIN", __dir__)
  FRAME_15BIT = File.expand_path("../.tests/mdec/frame/frame-15bit.exe", __dir__)
  FRAME_24BIT = File.expand_path("../.tests/mdec/frame/frame-24bit.exe", __dir__)

  def setup
    skip "BIOS not present" unless File.exist?(BIOS)
    skip "MDEC frame test EXEs not present" unless File.exist?(FRAME_15BIT) && File.exist?(FRAME_24BIT)
  end

  def test_frame_15bit_software_read_reaches_done
    captured = run_psexe_until_done(FRAME_15BIT)

    assert_includes captured, "Using framebuffer in 15bit mode"
    assert_equal 20, captured.scan(/mdec_readDecoded\(addr=.*?\)\.\.\. ok/).size,
                 "15-bit frame should complete all 20 software-read stripes"
    assert_includes captured, "Done"
  end

  def test_frame_24bit_software_read_reaches_done
    captured = run_psexe_until_done(FRAME_24BIT)

    assert_includes captured, "Using framebuffer in 24bit mode"
    assert_equal 20, captured.scan(/mdec_readDecoded\(addr=.*?\)\.\.\. /).size,
                 "24-bit frame should attempt all 20 software-read stripes"
    assert_includes captured, "Done"
  end

  private

  def run_psexe_until_done(path)
    emu = PSX::Emulator.new(BIOS)
    emu.run(steps: 5_000_000)

    captured = String.new
    emu.cpu.tty_handler = ->(kind, val) { captured << (kind == :char ? val.chr : val) }
    emu.load_psexe(path)

    remaining = 160_000_000
    step = 200_000
    until captured.include?("Done") || remaining <= 0
      emu.run(steps: step)
      remaining -= step
    end

    captured
  end
end
