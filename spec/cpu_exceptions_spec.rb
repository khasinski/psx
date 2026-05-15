# frozen_string_literal: true

require_relative "spec_helper"

# Conformance for the exceptions that psxtest_cpu's Exception column
# requires. Before these traps were wired up the test showed red on
# ADD/SUB/ADDI (overflow) and LH/LHU/LW/SH/SW (unaligned), with green on
# everything else.
class CPUExceptionsSpec < Minitest::Test
  include TestHelpers

  def setup
    @env = create_cpu_with_ram
    @cpu = @env[:cpu]
    @memory = @env[:memory]
  end

  def execute(addr, instr)
    @memory.write32(addr, instr)
    @cpu.pc = addr
    @cpu.step
  end

  def reg(n, v) @cpu.regs[n] = v & 0xFFFF_FFFF end

  # ADD overflow: 0x7FFFFFFF + 1 -> overflow trap, EPC = the ADD addr,
  # rd unchanged, exception vector entered.
  def test_add_overflow_traps
    reg(8, 0x7FFF_FFFF)  # $t0 = INT_MAX
    reg(9, 1)            # $t1 = 1
    reg(10, 0xDEAD_BEEF) # $t2 — should NOT be overwritten
    # add $t2, $t0, $t1  funct=0x20
    execute(0x8000_0000, 0x01095020)
    assert_equal PSX::COP0::EXC_OV << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0x8000_0000, @cpu.cop0.epc
    assert_equal 0xDEAD_BEEF, @cpu.regs[10], "rd must be preserved on overflow"
  end

  def test_add_no_overflow_writes_rd
    reg(8, 1); reg(9, 2); reg(10, 0)
    execute(0x8000_0000, 0x01095020)
    assert_equal 3, @cpu.regs[10]
    refute_equal PSX::COP0::EXC_OV << 2, @cpu.cop0.cause & 0x7C
  end

  def test_sub_overflow_traps
    reg(8, -0x8000_0000 & 0xFFFF_FFFF) # INT_MIN
    reg(9, 1)
    reg(10, 0xDEAD_BEEF)
    # sub $t2, $t0, $t1  funct=0x22
    execute(0x8000_0000, 0x01095022)
    assert_equal PSX::COP0::EXC_OV << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0xDEAD_BEEF, @cpu.regs[10]
  end

  def test_addi_overflow_traps
    reg(8, 0x7FFF_FFFF)
    reg(9, 0xDEAD_BEEF)
    # addi $t1, $t0, 1  opcode=0x08
    execute(0x8000_0000, 0x21090001)
    assert_equal PSX::COP0::EXC_OV << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0xDEAD_BEEF, @cpu.regs[9]
  end

  def test_lh_unaligned_traps
    reg(8, 0x8000_1001)  # $t0 = an odd address
    reg(9, 0xDEAD_BEEF)
    # lh $t1, 0($t0)  opcode=0x21
    execute(0x8000_0000, 0x85090000)
    assert_equal PSX::COP0::EXC_ADEL << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0x8000_1001, @cpu.cop0.read(PSX::COP0::BADVADDR)
    # No load-delay update should have happened.
    assert_equal 0xDEAD_BEEF, @cpu.regs[9]
  end

  def test_lw_unaligned_traps
    reg(8, 0x8000_1002)  # 2-aligned but not 4-aligned
    # lw $t1, 0($t0)  opcode=0x23
    execute(0x8000_0000, 0x8D090000)
    assert_equal PSX::COP0::EXC_ADEL << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0x8000_1002, @cpu.cop0.read(PSX::COP0::BADVADDR)
  end

  def test_sh_unaligned_traps
    reg(8, 0x8000_1001)
    reg(9, 0x4242)
    # sh $t1, 0($t0)  opcode=0x29
    execute(0x8000_0000, 0xA5090000)
    assert_equal PSX::COP0::EXC_ADES << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0x8000_1001, @cpu.cop0.read(PSX::COP0::BADVADDR)
  end

  def test_sw_unaligned_traps
    reg(8, 0x8000_1002)
    reg(9, 0xDEAD_BEEF)
    # sw $t1, 0($t0)  opcode=0x2B
    execute(0x8000_0000, 0xAD090000)
    assert_equal PSX::COP0::EXC_ADES << 2, @cpu.cop0.cause & 0x7C
    assert_equal 0x8000_1002, @cpu.cop0.read(PSX::COP0::BADVADDR)
  end
end
