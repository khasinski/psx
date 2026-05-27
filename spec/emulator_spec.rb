# frozen_string_literal: true

require_relative "spec_helper"

class EmulatorSpec < Minitest::Test
  BIOS = File.expand_path("../SCPH1001.BIN", __dir__)

  def setup
    skip "BIOS not present" unless File.exist?(BIOS)
  end

  def test_refreshes_bios_pad_buffers_from_controller_state
    emu = PSX::Emulator.new(BIOS)
    emu.memory.write32(0x8000_74C8, 0x8010_0000)
    emu.memory.write32(0x8000_74CC, 0x8010_0040)
    emu.memory.write32(0x8000_74D8, 0x28)
    emu.memory.write32(0x8000_74DC, 0x28)
    emu.controller_state_proc = -> { 0xFFF7 }

    emu.send(:refresh_bios_pad_buffers)

    assert_equal [0x00, 0x41, 0xF7, 0xFF], bytes_at(emu, 0x8010_0000, 4)
    assert_equal [0xFF, 0x00, 0x00, 0x00], bytes_at(emu, 0x8010_0040, 4)
  end

  def test_ignores_uninitialized_bios_pad_buffers
    emu = PSX::Emulator.new(BIOS)
    emu.controller_state_proc = -> { 0xFFF7 }

    emu.send(:refresh_bios_pad_buffers)

    assert_equal 0, emu.memory.read32(0x8000_0000)
  end

  private

  def bytes_at(emu, addr, count)
    count.times.map { |i| emu.memory.read8(addr + i) }
  end
end
