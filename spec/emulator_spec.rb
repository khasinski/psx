# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

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

  def test_tick_devices_refreshes_direct_pad_buffer_in_serial_order
    emu = PSX::Emulator.new(BIOS)
    emu.memory.write32(0x8000_74C8, 0x8010_0000)
    emu.memory.write32(0x8000_74D8, 0x28)
    emu.controller_state_proc = -> { 0xFFF7 }

    [0x00, 0x41, 0xFF, 0xFF].each_with_index { |byte, i| emu.memory.write8(0x8010_0000 + i, byte) }

    emu.send(:tick_devices)

    assert_equal [0x00, 0x41, 0xF7, 0xFF], bytes_at(emu, 0x8010_0000, 4)
  end

  def test_run_fast_refreshes_direct_pad_buffer_order
    emu = PSX::Emulator.new(BIOS)
    emu.memory.write32(0x8000_74C8, 0x8010_0000)
    emu.memory.write32(0x8000_74D8, 0x28)
    emu.controller_state_proc = -> { 0xFFF7 }

    emu.run(steps: 1)

    assert_equal [0x00, 0x41, 0xF7, 0xFF], bytes_at(emu, 0x8010_0000, 4)
  end

  def test_rage_direct_pad_decode_sees_start_as_bit_11
    emu = PSX::Emulator.new(BIOS)
    emu.memory.write32(0x8000_74C8, 0x8010_0000)
    emu.memory.write32(0x8000_74D8, 0x28)
    emu.controller_state_proc = -> { 0xFFF7 }

    emu.send(:refresh_bios_pad_buffers)
    bytes = bytes_at(emu, 0x8010_0000, 4)
    pressed = (~((bytes[2] << 8) | bytes[3])) & 0xFFFF

    assert_equal 0x0800, pressed & 0x0800
    assert_equal 0, pressed & 0x0008
  end

  def test_ignores_uninitialized_bios_pad_buffers
    emu = PSX::Emulator.new(BIOS)
    emu.controller_state_proc = -> { 0xFFF7 }

    emu.send(:refresh_bios_pad_buffers)

    assert_equal 0, emu.memory.read32(0x8000_0000)
  end

  def test_fast_boot_skips_retail_bios_boot_for_region_mismatch
    emu = PSX::Emulator.new(BIOS)
    emu.cdrom.disc = disc_with_region(:pal)

    refute emu.send(:retail_bios_boot_possible?)
  end

  def test_fast_boot_allows_retail_bios_boot_for_matching_region
    emu = PSX::Emulator.new(BIOS)
    emu.cdrom.disc = disc_with_region(:ntsc_u)

    assert emu.send(:retail_bios_boot_possible?)
  end

  def test_save_debug_snapshot_writes_state_and_screenshot
    emu = PSX::Emulator.new(BIOS)
    emu.gpu.vram[0] = 0x001F

    Dir.mktmpdir do |dir|
      paths = emu.save_debug_snapshot(File.join(dir, "rage-loading"))

      assert File.exist?(paths[:state]), "debug snapshot should write a save state"
      assert File.exist?(paths[:screenshot]), "debug snapshot should write a screenshot"
      assert_equal File.join(dir, "rage-loading.psxstate"), paths[:state]
      assert_equal File.join(dir, "rage-loading.ppm"), paths[:screenshot]
      assert_equal "P6", File.open(paths[:screenshot], &:readline).strip
    end
  end

  private

  def bytes_at(emu, addr, count)
    count.times.map { |i| emu.memory.read8(addr + i) }
  end

  def disc_with_region(region)
    Object.new.tap do |disc|
      disc.define_singleton_method(:region_code) { region }
    end
  end
end
