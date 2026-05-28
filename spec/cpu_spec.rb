# frozen_string_literal: true

require_relative "spec_helper"

class CPUSpec < Minitest::Test
  include TestHelpers

  def setup
    @env = create_cpu_with_ram
    @cpu = @env[:cpu]
    @memory = @env[:memory]
    @ram = @env[:ram]
  end

  # Helper to write instruction to RAM and execute
  def execute_at(addr, instruction)
    @memory.write32(addr, instruction)
    @cpu.instance_variable_set(:@pc, addr)
    @cpu.instance_variable_set(:@next_pc, addr + 4)
    @cpu.step
  end

  # Helper to set register
  def set_reg(reg, value)
    regs = @cpu.instance_variable_get(:@regs)
    regs[reg] = value & 0xFFFF_FFFF
  end

  # Helper to get register
  def get_reg(reg)
    @cpu.instance_variable_get(:@regs)[reg]
  end

  def setup_rage_intro_cdrom_stream
    cdrom = PSX::CDROM.new(interrupts: @env[:interrupts])
    cdrom.instance_variable_set(:@whole_sector, true)
    cdrom.instance_variable_set(:@reading, true)
    cdrom.instance_variable_set(:@seek_lba, 304)
    @memory.cdrom = cdrom
  end

  def setup_rage_stream_queue(entries)
    queue = 0x800F_F2E0
    @memory.write32(PSX::CPU::RAGE_STREAM_QUEUE_BASE_PTR, queue)
    @memory.write32(PSX::CPU::RAGE_STREAM_DMA_INDEX, 0)
    entries.each_with_index do |(state, sector_info), i|
      entry = queue + i * PSX::CPU::RAGE_STREAM_QUEUE_ENTRY_SIZE
      @memory.write16(entry, state)
      @memory.write32(entry + 4, sector_info)
    end
  end

  # === ALU Instructions ===

  def test_add_instruction
    set_reg(8, 100)   # $t0 = 100
    set_reg(9, 50)    # $t1 = 50

    # add $t2, $t0, $t1  (opcode: 000000 01000 01001 01010 00000 100000)
    # $t2 = $t0 + $t1
    execute_at(0x8000_0000, 0x01095020)

    assert_equal 150, get_reg(10), "$t2 should be 150"
  end

  def test_addi_instruction
    set_reg(8, 100)   # $t0 = 100

    # addi $t1, $t0, 25
    execute_at(0x8000_0000, 0x21090019)

    assert_equal 125, get_reg(9), "$t1 should be 125"
  end

  def test_sub_instruction
    set_reg(8, 100)
    set_reg(9, 30)

    # sub $t2, $t0, $t1
    execute_at(0x8000_0000, 0x01095022)

    assert_equal 70, get_reg(10), "$t2 should be 70"
  end

  def test_and_instruction
    set_reg(8, 0xFF00)
    set_reg(9, 0x0FF0)

    # and $t2, $t0, $t1
    execute_at(0x8000_0000, 0x01095024)

    assert_equal 0x0F00, get_reg(10)
  end

  def test_or_instruction
    set_reg(8, 0xFF00)
    set_reg(9, 0x00FF)

    # or $t2, $t0, $t1
    execute_at(0x8000_0000, 0x01095025)

    assert_equal 0xFFFF, get_reg(10)
  end

  def test_xor_instruction
    set_reg(8, 0xFFFF)
    set_reg(9, 0x0F0F)

    # xor $t2, $t0, $t1
    execute_at(0x8000_0000, 0x01095026)

    assert_equal 0xF0F0, get_reg(10)
  end

  def test_sll_instruction
    set_reg(9, 0x01)

    # sll $t2, $t1, 4
    execute_at(0x8000_0000, 0x00095100)

    assert_equal 0x10, get_reg(10)
  end

  def test_srl_instruction
    set_reg(9, 0x80)

    # srl $t2, $t1, 4
    execute_at(0x8000_0000, 0x00095102)

    assert_equal 0x08, get_reg(10)
  end

  def test_sra_preserves_sign
    set_reg(9, 0x8000_0000)  # Negative number

    # sra $t2, $t1, 4
    execute_at(0x8000_0000, 0x00095103)

    result = get_reg(10)
    assert result & 0x8000_0000 != 0, "Sign bit should be preserved"
  end

  def test_lui_instruction
    # lui $t0, 0x1234
    execute_at(0x8000_0000, 0x3C081234)

    assert_equal 0x1234_0000, get_reg(8)
  end

  # === Load/Store Instructions ===

  def test_lw_instruction
    # Write value to RAM
    @ram.write32(0x100, 0xDEAD_BEEF)
    set_reg(8, 0x100)  # Base address

    # lw $t1, 0($t0)
    execute_at(0x8000_0000, 0x8D090000)

    # Need to step again due to load delay slot
    execute_at(0x8000_0004, 0x00000000)  # nop

    assert_equal 0xDEAD_BEEF, get_reg(9)
  end

  def test_lw_delay_slot_uses_old_register_value
    @ram.write32(0x100, 0xDEAD_BEEF)
    set_reg(8, 0x100) # $t0 = base
    set_reg(9, 5)     # $t1 = old value

    @memory.write32(0x8000_0000, 0x8D09_0000) # lw    $t1, 0($t0)
    @memory.write32(0x8000_0004, 0x252A_0001) # addiu $t2, $t1, 1
    @memory.write32(0x8000_0008, 0x0000_0000) # nop
    @cpu.pc = 0x8000_0000

    @cpu.step
    @cpu.step

    assert_equal 6, get_reg(10),
                 "instruction after lw should see the old register value"
    assert_equal 0xDEAD_BEEF, get_reg(9),
                 "loaded value should commit after the delay-slot instruction"
  end

  def test_write_to_load_target_cancels_pending_load
    @ram.write32(0x100, 0xDEAD_BEEF)
    set_reg(8, 0x100)

    @memory.write32(0x8000_0000, 0x8D09_0000) # lw    $t1, 0($t0)
    @memory.write32(0x8000_0004, 0x2409_0007) # addiu $t1, $zero, 7
    @memory.write32(0x8000_0008, 0x0000_0000) # nop
    @cpu.pc = 0x8000_0000

    @cpu.step
    @cpu.step
    @cpu.step

    assert_equal 7, get_reg(9)
  end

  def test_lwl_lwr_pair_merges_through_pending_load_delay
    @ram.write8(0x100, 0x00)
    @ram.write8(0x101, 0x11)
    @ram.write8(0x102, 0x22)
    @ram.write8(0x103, 0x33)
    @ram.write8(0x104, 0x44)
    set_reg(8, 0x101)
    set_reg(9, 0xAA_AA_AA_AA)

    @memory.write32(0x8000_0000, 0x9909_0000) # lwr $t1, 0($t0)
    @memory.write32(0x8000_0004, 0x8909_0003) # lwl $t1, 3($t0)
    @memory.write32(0x8000_0008, 0x0000_0000) # nop
    @cpu.pc = 0x8000_0000

    @cpu.step
    @cpu.step
    @cpu.step

    assert_equal 0x4433_2211, get_reg(9)
  end

  def test_rage_cdrom_dma_callback_is_skipped_until_sector_group_is_complete
    setup_rage_intro_cdrom_stream
    setup_rage_stream_queue([[3, 0x0006_0000]])
    set_reg(31, 0x8000_1234)

    @memory.write32(PSX::CPU::RAGE_CDROM_DMA_CALLBACK, 0x2402_0007) # addiu $v0, $zero, 7
    @cpu.pc = PSX::CPU::RAGE_CDROM_DMA_CALLBACK
    @cpu.step

    assert_equal 0x8000_1234, @cpu.pc
    assert_equal 0, get_reg(2), "incomplete group must not run Rage's DMA callback"
  end

  def test_rage_cdrom_dma_callback_runs_after_sector_group_is_complete
    setup_rage_intro_cdrom_stream
    setup_rage_stream_queue((0...6).map { |i| [3, 0x0006_0000 | i] })
    set_reg(31, 0x8000_1234)

    @memory.write32(PSX::CPU::RAGE_CDROM_DMA_CALLBACK, 0x2402_0007) # addiu $v0, $zero, 7
    @cpu.pc = PSX::CPU::RAGE_CDROM_DMA_CALLBACK
    @cpu.step

    assert_equal 0x8006_CE7C, @cpu.pc
    assert_equal 7, get_reg(2)
  end

  def test_sw_instruction
    set_reg(8, 0x200)       # Base address
    set_reg(9, 0xCAFE_BABE) # Value to store

    # sw $t1, 0($t0)
    execute_at(0x8000_0000, 0xAD090000)

    assert_equal 0xCAFE_BABE, @ram.read32(0x200)
  end

  def test_lb_sign_extends
    @ram.write8(0x100, 0x80)  # -128 as signed byte
    set_reg(8, 0x100)

    # lb $t1, 0($t0)
    execute_at(0x8000_0000, 0x81090000)
    execute_at(0x8000_0004, 0x00000000)  # nop for delay

    result = get_reg(9)
    assert_equal 0xFFFF_FF80, result, "lb should sign-extend"
  end

  def test_lbu_zero_extends
    @ram.write8(0x100, 0x80)
    set_reg(8, 0x100)

    # lbu $t1, 0($t0)
    execute_at(0x8000_0000, 0x91090000)
    execute_at(0x8000_0004, 0x00000000)

    result = get_reg(9)
    assert_equal 0x80, result, "lbu should zero-extend"
  end

  # === Branch Instructions ===

  def test_beq_taken
    set_reg(8, 42)
    set_reg(9, 42)

    # beq $t0, $t1, +2 (skip 2 instructions)
    @memory.write32(0x8000_0004, 0x00000000)  # NOP in delay slot
    execute_at(0x8000_0000, 0x11090002)
    # Execute delay slot
    @cpu.step

    pc = @cpu.instance_variable_get(:@pc)
    assert_equal 0x8000_000C, pc, "Branch should be taken"
  end

  def test_beq_not_taken
    set_reg(8, 42)
    set_reg(9, 43)

    # beq $t0, $t1, +2
    @memory.write32(0x8000_0004, 0x00000000)  # NOP in delay slot
    execute_at(0x8000_0000, 0x11090002)
    @cpu.step

    pc = @cpu.instance_variable_get(:@pc)
    assert_equal 0x8000_0008, pc, "Branch should not be taken"
  end

  def test_bne_taken
    set_reg(8, 42)
    set_reg(9, 43)

    # bne $t0, $t1, +2
    @memory.write32(0x8000_0004, 0x00000000)  # NOP in delay slot
    execute_at(0x8000_0000, 0x15090002)
    @cpu.step

    pc = @cpu.instance_variable_get(:@pc)
    assert_equal 0x8000_000C, pc
  end

  def test_j_instruction
    # j 0x80001000
    @memory.write32(0x8000_0004, 0x00000000)  # NOP in delay slot
    execute_at(0x8000_0000, 0x08000400)
    @cpu.step  # delay slot

    pc = @cpu.instance_variable_get(:@pc)
    assert_equal 0x8000_1000, pc
  end

  def test_jal_saves_return_address
    # jal 0x80001000
    @memory.write32(0x8000_0004, 0x00000000)  # NOP in delay slot
    execute_at(0x8000_0000, 0x0C000400)
    @cpu.step

    ra = get_reg(31)  # $ra
    assert_equal 0x8000_0008, ra, "Return address should be PC+8"
  end

  def test_jr_instruction
    set_reg(8, 0x8000_2000)

    # jr $t0
    @memory.write32(0x8000_0004, 0x00000000)  # NOP in delay slot
    execute_at(0x8000_0000, 0x01000008)
    @cpu.step

    pc = @cpu.instance_variable_get(:@pc)
    assert_equal 0x8000_2000, pc
  end

  # === Register $zero Always Zero ===

  def test_zero_register_stays_zero
    # Try to write to $zero: add $zero, $t0, $t1
    set_reg(8, 100)
    set_reg(9, 200)

    execute_at(0x8000_0000, 0x01090020)  # add $zero, $t0, $t1

    assert_equal 0, get_reg(0), "$zero should always be 0"
  end

  # === Set Less Than ===

  def test_slt_signed_comparison
    set_reg(8, 0xFFFF_FFFF)  # -1 signed
    set_reg(9, 1)

    # slt $t2, $t0, $t1 (is -1 < 1? yes)
    execute_at(0x8000_0000, 0x0109502A)

    assert_equal 1, get_reg(10), "-1 should be less than 1"
  end

  def test_sltu_unsigned_comparison
    set_reg(8, 0xFFFF_FFFF)  # Very large unsigned
    set_reg(9, 1)

    # sltu $t2, $t0, $t1 (is 0xFFFFFFFF < 1? no)
    execute_at(0x8000_0000, 0x0109502B)

    assert_equal 0, get_reg(10), "0xFFFFFFFF should not be less than 1 unsigned"
  end

  # Regression: if an interrupt fires while the CPU is sitting on a branch
  # delay slot, the exception must record EPC = branch address and CAUSE.BD =
  # 1 so that RFE restarts the branch instead of skipping it. Skipping the
  # branch leaves whatever the delay slot set in registers (e.g. $s0 = 0)
  # but rejoins the non-taken path — which is what caused the BIOS shell to
  # hang in a tight poll with $s0 = 0 in the GPU dispatcher loop.
  def test_interrupt_in_delay_slot_records_branch_pc
    interrupts = @env[:interrupts]
    cop0 = @cpu.cop0

    # Enable interrupts and unmask IRQ line 0 (= I_STAT bit 0 / hardware IRQ).
    cop0.write(PSX::COP0::SR, PSX::COP0::SR_IEC | 0x0400)
    interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK)

    # Lay out two instructions in RAM at 0x8000_0000:
    #   0x8000_0000: beq $zero, $zero, +1     ; unconditional branch to 0x8000_0008
    #   0x8000_0004: addiu $s0, $zero, 0      ; delay slot: $s0 = 0
    # beq opcode 0x04, rs=0 rt=0 imm=1 -> 0x10000001
    @memory.write32(0x8000_0000, 0x10000001)
    @memory.write32(0x8000_0004, 0x24100000)  # addiu $s0,$zero,0
    @memory.write32(0x8000_0080, 0x0800_0000)  # dummy non-zero IRQ vector

    @cpu.pc = 0x8000_0000

    # Step the branch instruction. After this, @pc=delay_slot, @next_pc=target.
    @cpu.step
    refute_equal 0, @cpu.instance_variable_get(:@next_pc) - @cpu.instance_variable_get(:@pc),
                 "branch should have redirected @next_pc"

    # Pre-bake a pending VBlank IRQ. The interrupt check now lives in the
    # run loop (run_fast calls cpu.check_interrupts at the 64-cycle batch
    # boundary), so to exercise the "IRQ pending while about to enter the
    # delay slot" path we trigger the check directly. check_interrupts
    # snapshots @current_pc/@in_delay_slot from @pc/@next_in_delay_slot
    # before raising EXC_INT.
    interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    pc_before_delay_slot = @cpu.instance_variable_get(:@pc)
    @cpu.check_interrupts

    # The CPU should have taken the exception with EPC pointing at the
    # branch (= delay_slot - 4) and BD = 1.
    assert_equal pc_before_delay_slot - 4, cop0.epc,
                 "EPC must point at the branch, not the delay slot"
    assert_equal 0x8000_0000, cop0.cause & 0x8000_0000, "CAUSE.BD must be set"
  end

end
