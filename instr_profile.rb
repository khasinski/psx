#!/usr/bin/env ruby
# frozen_string_literal: true

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)

require_relative "lib/psx"

# Opcode names
OPCODE_NAMES = {
  0x00 => "SPECIAL", 0x01 => "BCONDZ", 0x02 => "J", 0x03 => "JAL",
  0x04 => "BEQ", 0x05 => "BNE", 0x06 => "BLEZ", 0x07 => "BGTZ",
  0x08 => "ADDI", 0x09 => "ADDIU", 0x0A => "SLTI", 0x0B => "SLTIU",
  0x0C => "ANDI", 0x0D => "ORI", 0x0E => "XORI", 0x0F => "LUI",
  0x10 => "COP0", 0x12 => "COP2/GTE",
  0x20 => "LB", 0x21 => "LH", 0x22 => "LWL", 0x23 => "LW",
  0x24 => "LBU", 0x25 => "LHU", 0x26 => "LWR",
  0x28 => "SB", 0x29 => "SH", 0x2A => "SWL", 0x2B => "SW", 0x2E => "SWR"
}

SPECIAL_NAMES = {
  0x00 => "SLL", 0x02 => "SRL", 0x03 => "SRA", 0x04 => "SLLV",
  0x06 => "SRLV", 0x07 => "SRAV", 0x08 => "JR", 0x09 => "JALR",
  0x0C => "SYSCALL", 0x0D => "BREAK",
  0x10 => "MFHI", 0x11 => "MTHI", 0x12 => "MFLO", 0x13 => "MTLO",
  0x18 => "MULT", 0x19 => "MULTU", 0x1A => "DIV", 0x1B => "DIVU",
  0x20 => "ADD", 0x21 => "ADDU", 0x22 => "SUB", 0x23 => "SUBU",
  0x24 => "AND", 0x25 => "OR", 0x26 => "XOR", 0x27 => "NOR",
  0x2A => "SLT", 0x2B => "SLTU"
}

emu = PSX::Emulator.new("SCPH1001.BIN")

# Count instructions
instruction_counts = Hash.new(0)
cpu = emu.cpu

original_execute = cpu.method(:execute)
cpu.define_singleton_method(:execute) do |instr|
  opcode = (instr >> 26) & 0x3F
  if opcode == 0
    funct = instr & 0x3F
    name = SPECIAL_NAMES[funct] || "SPECIAL_0x#{funct.to_s(16).upcase}"
    instruction_counts[name] += 1
  else
    name = OPCODE_NAMES[opcode] || "OP_0x#{opcode.to_s(16).upcase}"
    instruction_counts[name] += 1
  end
  original_execute.call(instr)
end

# Run
emu.run(steps: 500_000)

# Display
puts "\nInstruction frequency (top 20):"
instruction_counts.sort_by { |k, v| -v }.first(20).each do |name, count|
  pct = count.to_f / 500_000 * 100
  puts "  %5.1f%% %7d  %s" % [pct, count, name]
end
