# frozen_string_literal: true

module PSX
  module Disasm
    REG_NAMES = %w[
      zero at v0 v1 a0 a1 a2 a3
      t0 t1 t2 t3 t4 t5 t6 t7
      s0 s1 s2 s3 s4 s5 s6 s7
      t8 t9 k0 k1 gp sp fp ra
    ].freeze

    COP0_NAMES = {
      3 => "BPC", 5 => "BDA", 6 => "JUMPDEST", 7 => "DCIC",
      8 => "BadVAddr", 9 => "BDAM", 11 => "BPCM", 12 => "SR",
      13 => "CAUSE", 14 => "EPC", 15 => "PRId"
    }.freeze

    class << self
      def disassemble(pc, instruction)
        return format("%08X: %08X  nop", pc, instruction) if instruction == 0

        opcode = (instruction >> 26) & 0x3F
        text = decode(pc, instruction, opcode)
        format("%08X: %08X  %s", pc, instruction, text)
      end

      private

      def decode(pc, instruction, opcode)
        case opcode
        when 0x00 then decode_special(instruction)
        when 0x01 then decode_bcondz(pc, instruction)
        when 0x02 then decode_j("j", pc, instruction)
        when 0x03 then decode_j("jal", pc, instruction)
        when 0x04 then decode_branch("beq", pc, instruction)
        when 0x05 then decode_branch("bne", pc, instruction)
        when 0x06 then decode_branch_z("blez", pc, instruction)
        when 0x07 then decode_branch_z("bgtz", pc, instruction)
        when 0x08 then decode_imm_arith("addi", instruction)
        when 0x09 then decode_imm_arith("addiu", instruction)
        when 0x0A then decode_imm_arith("slti", instruction)
        when 0x0B then decode_imm_arith("sltiu", instruction)
        when 0x0C then decode_imm_logic("andi", instruction)
        when 0x0D then decode_imm_logic("ori", instruction)
        when 0x0E then decode_imm_logic("xori", instruction)
        when 0x0F then decode_lui(instruction)
        when 0x10 then decode_cop0(instruction)
        when 0x12 then decode_cop2(instruction)
        when 0x20 then decode_load("lb", instruction)
        when 0x21 then decode_load("lh", instruction)
        when 0x22 then decode_load("lwl", instruction)
        when 0x23 then decode_load("lw", instruction)
        when 0x24 then decode_load("lbu", instruction)
        when 0x25 then decode_load("lhu", instruction)
        when 0x26 then decode_load("lwr", instruction)
        when 0x28 then decode_store("sb", instruction)
        when 0x29 then decode_store("sh", instruction)
        when 0x2A then decode_store("swl", instruction)
        when 0x2B then decode_store("sw", instruction)
        when 0x2E then decode_store("swr", instruction)
        else
          format("??? (op=%02X)", opcode)
        end
      end

      def decode_special(instruction)
        funct = instruction & 0x3F
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        rd = (instruction >> 11) & 0x1F
        shamt = (instruction >> 6) & 0x1F

        case funct
        when 0x00 then format("sll %s, %s, %d", reg(rd), reg(rt), shamt)
        when 0x02 then format("srl %s, %s, %d", reg(rd), reg(rt), shamt)
        when 0x03 then format("sra %s, %s, %d", reg(rd), reg(rt), shamt)
        when 0x04 then format("sllv %s, %s, %s", reg(rd), reg(rt), reg(rs))
        when 0x06 then format("srlv %s, %s, %s", reg(rd), reg(rt), reg(rs))
        when 0x07 then format("srav %s, %s, %s", reg(rd), reg(rt), reg(rs))
        when 0x08 then format("jr %s", reg(rs))
        when 0x09 then format("jalr %s, %s", reg(rd), reg(rs))
        when 0x0C then "syscall"
        when 0x0D then "break"
        when 0x10 then format("mfhi %s", reg(rd))
        when 0x11 then format("mthi %s", reg(rs))
        when 0x12 then format("mflo %s", reg(rd))
        when 0x13 then format("mtlo %s", reg(rs))
        when 0x18 then format("mult %s, %s", reg(rs), reg(rt))
        when 0x19 then format("multu %s, %s", reg(rs), reg(rt))
        when 0x1A then format("div %s, %s", reg(rs), reg(rt))
        when 0x1B then format("divu %s, %s", reg(rs), reg(rt))
        when 0x20 then format("add %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x21 then format("addu %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x22 then format("sub %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x23 then format("subu %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x24 then format("and %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x25 then format("or %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x26 then format("xor %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x27 then format("nor %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x2A then format("slt %s, %s, %s", reg(rd), reg(rs), reg(rt))
        when 0x2B then format("sltu %s, %s, %s", reg(rd), reg(rs), reg(rt))
        else
          format("??? (special funct=%02X)", funct)
        end
      end

      def decode_bcondz(pc, instruction)
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = instruction & 0xFFFF
        offset = sign_extend16(imm) << 2
        target = (pc + 4 + offset) & 0xFFFF_FFFF

        link = (rt & 0x10) != 0
        bgez = (rt & 0x01) != 0

        name = if bgez
          link ? "bgezal" : "bgez"
        else
          link ? "bltzal" : "bltz"
        end

        format("%s %s, 0x%08X", name, reg(rs), target)
      end

      def decode_j(name, pc, instruction)
        target = instruction & 0x03FF_FFFF
        addr = ((pc + 4) & 0xF000_0000) | (target << 2)
        format("%s 0x%08X", name, addr)
      end

      def decode_branch(name, pc, instruction)
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = instruction & 0xFFFF
        offset = sign_extend16(imm) << 2
        target = (pc + 4 + offset) & 0xFFFF_FFFF
        format("%s %s, %s, 0x%08X", name, reg(rs), reg(rt), target)
      end

      def decode_branch_z(name, pc, instruction)
        rs = (instruction >> 21) & 0x1F
        imm = instruction & 0xFFFF
        offset = sign_extend16(imm) << 2
        target = (pc + 4 + offset) & 0xFFFF_FFFF
        format("%s %s, 0x%08X", name, reg(rs), target)
      end

      def decode_imm_arith(name, instruction)
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = sign_extend16(instruction & 0xFFFF)
        format("%s %s, %s, %d", name, reg(rt), reg(rs), imm)
      end

      def decode_imm_logic(name, instruction)
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = instruction & 0xFFFF
        format("%s %s, %s, 0x%04X", name, reg(rt), reg(rs), imm)
      end

      def decode_lui(instruction)
        rt = (instruction >> 16) & 0x1F
        imm = instruction & 0xFFFF
        format("lui %s, 0x%04X", reg(rt), imm)
      end

      def decode_load(name, instruction)
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = sign_extend16(instruction & 0xFFFF)
        format("%s %s, %d(%s)", name, reg(rt), imm, reg(rs))
      end

      def decode_store(name, instruction)
        rs = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        imm = sign_extend16(instruction & 0xFFFF)
        format("%s %s, %d(%s)", name, reg(rt), imm, reg(rs))
      end

      def decode_cop0(instruction)
        cop_op = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        rd = (instruction >> 11) & 0x1F

        case cop_op
        when 0x00 then format("mfc0 %s, %s", reg(rt), cop0_reg(rd))
        when 0x04 then format("mtc0 %s, %s", reg(rt), cop0_reg(rd))
        when 0x10 then "rfe"
        else
          format("cop0 (op=%02X)", cop_op)
        end
      end

      def decode_cop2(instruction)
        cop_op = (instruction >> 21) & 0x1F
        rt = (instruction >> 16) & 0x1F
        rd = (instruction >> 11) & 0x1F

        case cop_op
        when 0x00 then format("mfc2 %s, $%d", reg(rt), rd)
        when 0x02 then format("cfc2 %s, $%d", reg(rt), rd)
        when 0x04 then format("mtc2 %s, $%d", reg(rt), rd)
        when 0x06 then format("ctc2 %s, $%d", reg(rt), rd)
        else
          cmd = instruction & 0x1FF_FFFF
          format("cop2 cmd=0x%07X", cmd)
        end
      end

      def reg(n)
        "$#{REG_NAMES[n]}"
      end

      def cop0_reg(n)
        COP0_NAMES[n] || "$#{n}"
      end

      def sign_extend16(val)
        (val & 0x8000) != 0 ? (val - 0x1_0000) : val
      end
    end
  end
end
