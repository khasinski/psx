# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

# Round-trip test: boot N cycles, save, load on a fresh emulator, run N
# more, and compare to a control emulator that ran 2N cycles straight
# through. The two must match exactly — same PC, same registers, same
# RAM, same VRAM. If they don't, the save state is missing some piece
# of internal state.
class SaveStateSpec < Minitest::Test
  BIOS = File.expand_path("../SCPH1001.BIN", __dir__)

  def setup
    skip "BIOS not present" unless File.exist?(BIOS)
  end

  def test_round_trip_after_bios_boot
    boot_cycles = 20_000_000
    continue_cycles = 5_000_000

    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "round_trip.psxstate")

      # 1. Boot, save, then continue.
      saver = PSX::Emulator.new(BIOS)
      saver.run(steps: boot_cycles)
      saver.save_state(state_path)
      saver.run(steps: continue_cycles)
      saver_snapshot = capture_snapshot(saver)

      # 2. Load on a fresh emulator and continue the same amount.
      loader = PSX::Emulator.new(BIOS)
      loader.load_state(state_path)
      loader.run(steps: continue_cycles)
      loader_snapshot = capture_snapshot(loader)

      assert_equal saver_snapshot[:pc], loader_snapshot[:pc],
                   "PC diverged after #{continue_cycles} continued cycles"
      assert_equal saver_snapshot[:regs], loader_snapshot[:regs], "register file diverged"
      assert_equal saver_snapshot[:hi], loader_snapshot[:hi], "HI diverged"
      assert_equal saver_snapshot[:lo], loader_snapshot[:lo], "LO diverged"
      assert_equal saver_snapshot[:ram], loader_snapshot[:ram], "RAM diverged"
      assert_equal saver_snapshot[:vram], loader_snapshot[:vram], "VRAM diverged"
      assert_equal saver_snapshot[:cycle_count], loader_snapshot[:cycle_count], "cycle_count diverged"
    end
  end

  def test_bios_fingerprint_mismatch_raises
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "fp.psxstate")
      emu = PSX::Emulator.new(BIOS)
      emu.run(steps: 100_000)
      emu.save_state(state_path)

      # Tamper the SHA in the saved payload so the load path rejects it.
      data = Marshal.load(File.binread(state_path))
      data[:bios_sha1] = "0" * 40
      File.binwrite(state_path, Marshal.dump(data))

      fresh = PSX::Emulator.new(BIOS)
      assert_raises(RuntimeError, "should reject mismatched BIOS") do
        fresh.load_state(state_path)
      end
    end
  end

  private

  def capture_snapshot(emu)
    {
      pc:          emu.cpu.pc,
      regs:        emu.cpu.regs.dup,
      hi:          emu.cpu.hi,
      lo:          emu.cpu.lo,
      ram:         emu.memory.ram_words.dup,
      vram:        emu.gpu.instance_variable_get(:@vram).dup,
      cycle_count: emu.instance_variable_get(:@cycle_count),
    }
  end
end
