# frozen_string_literal: true

require_relative "spec_helper"

# Direct check of what amidog's psxtest_gte OFFICIAL.TIMING column does:
# put Timer 2 in raw sysclock mode, execute a GTE COP2 command from
# WRAM, and read the Timer 2 counter delta. The delta must match the
# nocash-documented cycle count for that opcode.
class GteTimingTest < Minitest::Test
  PC_BASE = 0x8000_0000
  TIMER2_CNT  = 0x1F801120
  TIMER2_MODE = 0x1F801124

  # opcode -> nocash cycle count
  EXPECTED = {
    0x01 => 15,  # RTPS
    0x06 => 8,   # NCLIP
    0x0C => 6,   # OP
    0x10 => 8,   # DPCS
    0x11 => 8,   # INTPL
    0x12 => 8,   # MVMVA
    0x13 => 19,  # NCDS
    0x14 => 13,  # CDP
    0x16 => 44,  # NCDT
    0x1B => 17,  # NCCS
    0x1C => 11,  # CC
    0x1E => 14,  # NCS
    0x20 => 30,  # NCT
    0x28 => 5,   # SQR
    0x29 => 8,   # DCPL
    0x2A => 17,  # DPCT
    0x2D => 5,   # AVSZ3
    0x2E => 6,   # AVSZ4
    0x30 => 23,  # RTPT
    0x3D => 5,   # GPF
    0x3E => 5,   # GPL
    0x3F => 39   # NCCT
  }.freeze

  def setup
    @bios = mini_bios
    @interrupts = PSX::Interrupts.new
    @ram = PSX::RAM.new
    @gpu = PSX::GPU.new(interrupts: @interrupts)
    @spu = PSX::SPU.new
    @cdrom = PSX::CDROM.new(interrupts: @interrupts)
    @dma = PSX::DMA.new(interrupts: @interrupts, spu: @spu, cdrom: @cdrom)
    @timers = PSX::Timers.new(interrupts: @interrupts)
    @sio0 = PSX::SIO0.new(interrupts: @interrupts, controller_state: -> { 0xFFFF })
    @memory = PSX::Memory.new(
      bios: @bios, ram: @ram, interrupts: @interrupts,
      dma: @dma, timers: @timers, cdrom: @cdrom, sio0: @sio0, spu: @spu
    )
    @memory.gpu = @gpu
    @dma.memory = @memory
    @cpu = PSX::CPU.new(@memory, interrupts: @interrupts)
    @cpu.cop0.sr = PSX::COP0::SR_CU2  # enable GTE
  end

  # Provide a stub BIOS that's just zeroes — we never jump there.
  def mini_bios
    Class.new do
      def initialize = @data = "\x00" * 0x80000
      def read8(offset) = @data.getbyte(offset & 0x7FFFF)
      def read16(offset) = @data.unpack1("v", offset: offset & 0x7FFFF)
      def read32(offset) = @data.unpack1("V", offset: offset & 0x7FFFF)
      def size = @data.bytesize
    end.new
  end

  def test_each_gte_opcode_advances_timer2_by_its_cycle_count
    # The amidog test puts Timer 2 in src=0 (sysclock) with no reset/IRQ
    # and clears its counter, then reads counter before and after each
    # GTE op to compute the delta.
    EXPECTED.each do |opcode, expected_cycles|
      @timers.write(0x24, 0)         # Timer 2 mode = 0 (sysclock)
      @timers.write(0x20, 0)         # Reset Timer 2 counter

      # COP2 command instruction: opcode bits 5..0, imm25 bit set,
      # high nibble 0x4B = COP2 with bit 25 set.
      instr = 0x4A_00_00_00 | (1 << 25) | (opcode & 0x3F)

      delta = run_one_gte_op(instr)
      assert_equal expected_cycles, delta,
        "GTE opcode 0x#{opcode.to_s(16)} expected #{expected_cycles} cycles, got #{delta}"
    end
  end

  private

  def run_one_gte_op(instr)
    # Write the GTE instruction at PC_BASE, then step once.
    @memory.write32(PC_BASE, instr)
    @cpu.pc = PC_BASE

    before = @timers.read(0x20)
    @cpu.step
    # Mirror PSX::Emulator.run_fast: apply the instruction's full
    # step_cycles to the timers.
    @timers.tick(@cpu.step_cycles)
    after = @timers.read(0x20)
    after - before
  end
end
