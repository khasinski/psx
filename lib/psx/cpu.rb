# frozen_string_literal: true

require_relative "cop0"

module PSX
  class CPU
    class ExecutionError < StandardError; end

    RESET_VECTOR = 0xBFC0_0000  # BIOS entry point

    attr_reader :pc, :regs, :hi, :lo, :memory, :cop0

    def initialize(memory, interrupts: nil)
      @memory = memory
      @interrupts = interrupts
      @regs = Array.new(32, 0)  # R0 is always 0
      @pc = RESET_VECTOR
      @next_pc = @pc + 4
      @hi = 0
      @lo = 0

      # Coprocessor 0
      @cop0 = COP0.new

      # Delayed load handling
      @load_delay_reg = 0
      @load_delay_value = 0

      # Branch delay slot tracking
      @in_delay_slot = false
      @branch_target = nil
      @current_pc = @pc

      # Interrupt check counter - only check every N cycles
      @interrupt_check_counter = 0
      @interrupt_check_interval = 64
    end

    def step
      # Check for pending interrupts (only every N cycles for performance)
      @interrupt_check_counter += 1
      if @interrupt_check_counter >= @interrupt_check_interval
        @interrupt_check_counter = 0
        check_interrupts
      end

      # Save current PC for exception handling
      pc = @pc
      @current_pc = pc

      # Fetch instruction
      instruction = @memory.read32(pc)

      # Track if we're in a delay slot and get branch target
      branch_target = @branch_target
      @in_delay_slot = !branch_target.nil?

      # Update PC (must use @next_pc which may have been modified by previous branch)
      next_pc = @next_pc
      @pc = next_pc
      @next_pc = next_pc + 4

      # Apply pending load (inlined for performance)
      load_reg = @load_delay_reg
      if load_reg != 0
        @regs[load_reg] = @load_delay_value
        @load_delay_reg = 0
      end

      # Execute (skip NOP)
      execute(instruction) if instruction != 0

      # Handle branch delay (check @branch_target as instruction may have set new one)
      new_branch = @branch_target
      if new_branch
        @next_pc = new_branch
        @branch_target = nil
      end
    end

    def disassemble_current
      instruction = @memory.read32(@pc)
      Disasm.disassemble(@pc, instruction)
    end

    def dump_registers
      lines = ["Registers:"]
      (0...32).each_slice(4) do |slice|
        row = slice.map { |i| format("R%-2d=%08X", i, @regs[i]) }.join("  ")
        lines << row
      end
      lines << format("PC=%08X  HI=%08X  LO=%08X", @pc, @hi, @lo)
      lines << format("SR=%08X  CAUSE=%08X  EPC=%08X", @cop0.sr, @cop0.cause, @cop0.epc)
      lines.join("\n")
    end

    private

    def check_interrupts
      return unless @interrupts

      # Update hardware IRQ status in COP0
      @cop0.set_hardware_irq(@interrupts.pending?)

      # If interrupts are pending and enabled, trigger exception
      if @cop0.interrupt_pending?
        exception(COP0::EXC_INT)
      end
    end

    def apply_load_delay
      if @load_delay_reg != 0
        @regs[@load_delay_reg] = @load_delay_value
        @load_delay_reg = 0
      end
    end

    def set_reg(reg, value)
      # If we're setting a register that has a pending load, cancel the load
      @load_delay_reg = 0 if @load_delay_reg == reg
      @regs[reg] = value & 0xFFFF_FFFF if reg != 0
    end

    def set_reg_delayed(reg, value)
      # Delayed loads - value appears after next instruction
      @load_delay_reg = reg
      @load_delay_value = value & 0xFFFF_FFFF
    end

    def branch(offset)
      # offset is already sign-extended 16-bit << 2
      @branch_target = (@pc + offset) & 0xFFFF_FFFF  # PC already advanced by 4
    end

    def jump(target)
      @branch_target = target & 0xFFFF_FFFF
    end

    def sign_extend8(value)
      (value & 0x80) != 0 ? (value | 0xFFFF_FF00) : value
    end

    def sign_extend16(value)
      (value & 0x8000) != 0 ? (value | 0xFFFF_0000) : value
    end

    def sign_extend32(value)
      # Convert to signed 32-bit for Ruby
      (value & 0x8000_0000) != 0 ? (value - 0x1_0000_0000) : value
    end

    def execute(instruction)
      # NOP check done in step() for performance
      opcode = (instruction >> 26) & 0x3F

      case opcode
      when 0x00 then execute_special(instruction)
      when 0x01 then execute_bcondz(instruction)
      when 0x02 then op_j(instruction)
      when 0x03 then op_jal(instruction)
      when 0x04 then op_beq(instruction)
      when 0x05 then op_bne(instruction)
      when 0x06 then op_blez(instruction)
      when 0x07 then op_bgtz(instruction)
      when 0x08 then op_addi(instruction)
      when 0x09 then op_addiu(instruction)
      when 0x0A then op_slti(instruction)
      when 0x0B then op_sltiu(instruction)
      when 0x0C then op_andi(instruction)
      when 0x0D then op_ori(instruction)
      when 0x0E then op_xori(instruction)
      when 0x0F then op_lui(instruction)
      when 0x10 then execute_cop0(instruction)
      when 0x12 then execute_cop2(instruction)  # GTE
      when 0x20 then op_lb(instruction)
      when 0x21 then op_lh(instruction)
      when 0x22 then op_lwl(instruction)
      when 0x23 then op_lw(instruction)
      when 0x24 then op_lbu(instruction)
      when 0x25 then op_lhu(instruction)
      when 0x26 then op_lwr(instruction)
      when 0x28 then op_sb(instruction)
      when 0x29 then op_sh(instruction)
      when 0x2A then op_swl(instruction)
      when 0x2B then op_sw(instruction)
      when 0x2E then op_swr(instruction)
      else
        raise ExecutionError, format("Unknown opcode 0x%02X at PC=0x%08X", opcode, @pc - 4)
      end
    end

    def execute_special(instruction)
      funct = instruction & 0x3F

      case funct
      when 0x00 then op_sll(instruction)
      when 0x02 then op_srl(instruction)
      when 0x03 then op_sra(instruction)
      when 0x04 then op_sllv(instruction)
      when 0x06 then op_srlv(instruction)
      when 0x07 then op_srav(instruction)
      when 0x08 then op_jr(instruction)
      when 0x09 then op_jalr(instruction)
      when 0x0C then op_syscall(instruction)
      when 0x0D then op_break(instruction)
      when 0x10 then op_mfhi(instruction)
      when 0x11 then op_mthi(instruction)
      when 0x12 then op_mflo(instruction)
      when 0x13 then op_mtlo(instruction)
      when 0x18 then op_mult(instruction)
      when 0x19 then op_multu(instruction)
      when 0x1A then op_div(instruction)
      when 0x1B then op_divu(instruction)
      when 0x20 then op_add(instruction)
      when 0x21 then op_addu(instruction)
      when 0x22 then op_sub(instruction)
      when 0x23 then op_subu(instruction)
      when 0x24 then op_and(instruction)
      when 0x25 then op_or(instruction)
      when 0x26 then op_xor(instruction)
      when 0x27 then op_nor(instruction)
      when 0x2A then op_slt(instruction)
      when 0x2B then op_sltu(instruction)
      else
        raise ExecutionError, format("Unknown SPECIAL funct 0x%02X at PC=0x%08X", funct, @pc - 4)
      end
    end

    def execute_bcondz(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = sign_extend16(instruction & 0xFFFF)
      offset = imm << 2

      val = sign_extend32(@regs[rs])
      link = (rt & 0x10) != 0
      bgez = (rt & 0x01) != 0

      test = bgez ? (val >= 0) : (val < 0)

      # Link stores return address in R31
      set_reg(31, @next_pc) if link

      branch(offset) if test
    end

    def execute_cop0(instruction)
      cop_op = (instruction >> 21) & 0x1F

      case cop_op
      when 0x00 then op_mfc0(instruction)
      when 0x04 then op_mtc0(instruction)
      when 0x10 then op_rfe(instruction)
      else
        raise ExecutionError, format("Unknown COP0 op 0x%02X at PC=0x%08X", cop_op, @pc - 4)
      end
    end

    def execute_cop2(instruction)
      # GTE - stub for now
      cop_op = (instruction >> 21) & 0x1F

      case cop_op
      when 0x00  # MFC2
        rt = (instruction >> 16) & 0x1F
        set_reg_delayed(rt, 0)
      when 0x02  # CFC2
        rt = (instruction >> 16) & 0x1F
        set_reg_delayed(rt, 0)
      when 0x04  # MTC2
        # Move to GTE data register - ignore for now
      when 0x06  # CTC2
        # Move to GTE control register - ignore for now
      else
        # GTE command - ignore for now
      end
    end

    # R-type ALU operations (decode inlined for performance)
    def op_sll(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      shamt = (instruction >> 6) & 0x1F
      set_reg(rd, @regs[rt] << shamt)
    end

    def op_srl(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      shamt = (instruction >> 6) & 0x1F
      set_reg(rd, @regs[rt] >> shamt)
    end

    def op_sra(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      shamt = (instruction >> 6) & 0x1F
      val = sign_extend32(@regs[rt])
      set_reg(rd, val >> shamt)
    end

    def op_sllv(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rt] << (@regs[rs] & 0x1F))
    end

    def op_srlv(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rt] >> (@regs[rs] & 0x1F))
    end

    def op_srav(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      val = sign_extend32(@regs[rt])
      set_reg(rd, val >> (@regs[rs] & 0x1F))
    end

    def op_jr(instruction)
      rs = (instruction >> 21) & 0x1F
      jump(@regs[rs])
    end

    def op_jalr(instruction)
      rs = (instruction >> 21) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @next_pc)
      jump(@regs[rs])
    end

    def op_syscall(_instruction)
      exception(COP0::EXC_SYS)
    end

    def op_break(_instruction)
      exception(COP0::EXC_BP)
    end

    def op_mfhi(instruction)
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @hi)
    end

    def op_mthi(instruction)
      rs = (instruction >> 21) & 0x1F
      @hi = @regs[rs]
    end

    def op_mflo(instruction)
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @lo)
    end

    def op_mtlo(instruction)
      rs = (instruction >> 21) & 0x1F
      @lo = @regs[rs]
    end

    def op_mult(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      a = sign_extend32(@regs[rs])
      b = sign_extend32(@regs[rt])
      result = a * b
      @lo = result & 0xFFFF_FFFF
      @hi = (result >> 32) & 0xFFFF_FFFF
    end

    def op_multu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      result = @regs[rs] * @regs[rt]
      @lo = result & 0xFFFF_FFFF
      @hi = (result >> 32) & 0xFFFF_FFFF
    end

    def op_div(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      num = sign_extend32(@regs[rs])
      den = sign_extend32(@regs[rt])

      if den == 0
        # Division by zero
        @lo = num >= 0 ? 0xFFFF_FFFF : 1
        @hi = @regs[rs]
      elsif num == -0x8000_0000 && den == -1
        # Overflow
        @lo = 0x8000_0000
        @hi = 0
      else
        @lo = (num / den) & 0xFFFF_FFFF
        @hi = (num % den) & 0xFFFF_FFFF
      end
    end

    def op_divu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      num = @regs[rs]
      den = @regs[rt]

      if den == 0
        @lo = 0xFFFF_FFFF
        @hi = num
      else
        @lo = num / den
        @hi = num % den
      end
    end

    def op_add(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      # TODO: overflow trap
      set_reg(rd, @regs[rs] + @regs[rt])
    end

    def op_addu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rs] + @regs[rt])
    end

    def op_sub(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      # TODO: overflow trap
      set_reg(rd, @regs[rs] - @regs[rt])
    end

    def op_subu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rs] - @regs[rt])
    end

    def op_and(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rs] & @regs[rt])
    end

    def op_or(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rs] | @regs[rt])
    end

    def op_xor(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rs] ^ @regs[rt])
    end

    def op_nor(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, ~(@regs[rs] | @regs[rt]))
    end

    def op_slt(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      a = sign_extend32(@regs[rs])
      b = sign_extend32(@regs[rt])
      set_reg(rd, a < b ? 1 : 0)
    end

    def op_sltu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg(rd, @regs[rs] < @regs[rt] ? 1 : 0)
    end

    # I-type operations (decode inlined for performance)
    def op_addi(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # TODO: overflow trap
      set_reg(rt, @regs[rs] + sign_extend16(imm))
    end

    def op_addiu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # Inline sign_extend16 and set_reg for hot path
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
      @load_delay_reg = 0 if @load_delay_reg == rt
      @regs[rt] = (@regs[rs] + imm) & 0xFFFF_FFFF if rt != 0
    end

    def op_slti(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      a = sign_extend32(@regs[rs])
      b = sign_extend16(imm)
      b = sign_extend32(b & 0xFFFF_FFFF)
      set_reg(rt, a < b ? 1 : 0)
    end

    def op_sltiu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] < (sign_extend16(imm) & 0xFFFF_FFFF) ? 1 : 0)
    end

    def op_andi(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] & imm)
    end

    def op_ori(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] | imm)
    end

    def op_xori(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, @regs[rs] ^ imm)
    end

    def op_lui(instruction)
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      set_reg(rt, imm << 16)
    end

    # Branch operations (decode inlined)
    def op_beq(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      branch(sign_extend16(imm) << 2) if @regs[rs] == @regs[rt]
    end

    def op_bne(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      branch(sign_extend16(imm) << 2) if @regs[rs] != @regs[rt]
    end

    def op_blez(instruction)
      rs = (instruction >> 21) & 0x1F
      imm = instruction & 0xFFFF
      branch(sign_extend16(imm) << 2) if sign_extend32(@regs[rs]) <= 0
    end

    def op_bgtz(instruction)
      rs = (instruction >> 21) & 0x1F
      val = @regs[rs]
      # sign_extend32 check: value > 0 and not negative (high bit clear or value is 0)
      if val != 0 && (val & 0x8000_0000) == 0
        imm = instruction & 0xFFFF
        imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
        @branch_target = (@pc + (imm << 2)) & 0xFFFF_FFFF
      end
    end

    # Jump operations (decode inlined)
    def op_j(instruction)
      target = instruction & 0x03FF_FFFF
      jump((@pc & 0xF000_0000) | (target << 2))
    end

    def op_jal(instruction)
      target = instruction & 0x03FF_FFFF
      set_reg(31, @next_pc)
      jump((@pc & 0xF000_0000) | (target << 2))
    end

    # Load operations (decode inlined)
    def op_lb(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = @regs[rs] + sign_extend16(imm)
      val = sign_extend8(@memory.read8(addr))
      set_reg_delayed(rt, val)
    end

    def op_lh(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = @regs[rs] + sign_extend16(imm)
      val = sign_extend16(@memory.read16(addr))
      set_reg_delayed(rt, val)
    end

    def op_lw(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      set_reg_delayed(rt, @memory.read32(addr))
    end

    def op_lbu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # Inline sign_extend16
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
      addr = (@regs[rs] + imm) & 0xFFFF_FFFF
      # Inline set_reg_delayed
      @load_delay_reg = rt
      @load_delay_value = @memory.read8(addr)
    end

    def op_lhu(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = @regs[rs] + sign_extend16(imm)
      set_reg_delayed(rt, @memory.read16(addr))
    end

    def op_lwl(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)

      # Merge with existing register value
      current = @regs[rt]
      case addr & 3
      when 0 then result = (current & 0x00FF_FFFF) | (val << 24)
      when 1 then result = (current & 0x0000_FFFF) | (val << 16)
      when 2 then result = (current & 0x0000_00FF) | (val << 8)
      when 3 then result = val
      end
      set_reg_delayed(rt, result)
    end

    def op_lwr(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)

      current = @regs[rt]
      case addr & 3
      when 0 then result = val
      when 1 then result = (current & 0xFF00_0000) | (val >> 8)
      when 2 then result = (current & 0xFFFF_0000) | (val >> 16)
      when 3 then result = (current & 0xFFFF_FF00) | (val >> 24)
      end
      set_reg_delayed(rt, result)
    end

    # Store operations (decode inlined)
    def op_sb(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      # Inline sign_extend16
      imm = imm | 0xFFFF_0000 if (imm & 0x8000) != 0
      addr = (@regs[rs] + imm) & 0xFFFF_FFFF
      @memory.write8(addr, @regs[rt])
    end

    def op_sh(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      @memory.write16(addr, @regs[rt])
    end

    def op_sw(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      @memory.write32(addr, @regs[rt])
    end

    def op_swl(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)
      reg = @regs[rt]

      case addr & 3
      when 0 then result = (val & 0xFFFF_FF00) | (reg >> 24)
      when 1 then result = (val & 0xFFFF_0000) | (reg >> 16)
      when 2 then result = (val & 0xFF00_0000) | (reg >> 8)
      when 3 then result = reg
      end
      @memory.write32(aligned, result)
    end

    def op_swr(instruction)
      rs = (instruction >> 21) & 0x1F
      rt = (instruction >> 16) & 0x1F
      imm = instruction & 0xFFFF
      addr = (@regs[rs] + sign_extend16(imm)) & 0xFFFF_FFFF
      aligned = addr & ~3
      val = @memory.read32(aligned)
      reg = @regs[rt]

      case addr & 3
      when 0 then result = reg
      when 1 then result = (val & 0x0000_00FF) | (reg << 8)
      when 2 then result = (val & 0x0000_FFFF) | (reg << 16)
      when 3 then result = (val & 0x00FF_FFFF) | (reg << 24)
      end
      @memory.write32(aligned, result)
    end

    # COP0 operations
    def op_mfc0(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      set_reg_delayed(rt, @cop0.read(rd))
    end

    def op_mtc0(instruction)
      rt = (instruction >> 16) & 0x1F
      rd = (instruction >> 11) & 0x1F
      val = @regs[rt]

      @cop0.write(rd, val)

      # Update memory cache isolation state
      @memory.cache_isolated = @cop0.cache_isolated? if rd == COP0::SR
    end

    def op_rfe(_instruction)
      @cop0.return_from_exception
    end

    def exception(cause, bad_addr: nil)
      # Enter exception, get vector address
      vector = @cop0.enter_exception(
        cause,
        @current_pc,
        in_delay_slot: @in_delay_slot,
        bad_addr: bad_addr
      )

      # Jump to exception vector
      @pc = vector
      @next_pc = @pc + 4
      @branch_target = nil
    end
  end
end
