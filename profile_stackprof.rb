# frozen_string_literal: true

require "stackprof"
require_relative "lib/psx"

BIOS_PATH = "SCPH1001.BIN"
CYCLES = 1_000_000

unless File.exist?(BIOS_PATH)
  puts "BIOS not found: #{BIOS_PATH}"
  exit 1
end

puts "PSX-Ruby CPU Profiler"
puts "====================="
puts "Cycles: #{CYCLES.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')}"
puts ""

emu = PSX::Emulator.new(BIOS_PATH)

# Warm up
puts "Warming up (100k cycles)..."
emu.run(steps: 100_000)

# Profile CPU mode (method-level)
puts "Profiling CPU (wall time)..."
StackProf.run(mode: :wall, out: "stackprof-wall.dump", raw: true) do
  emu.run(steps: CYCLES)
end

# Report
puts ""
puts "Top methods by wall time:"
puts "=" * 60

report = StackProf::Report.new(Marshal.load(File.binread("stackprof-wall.dump")))
report.print_text(false, 30)

puts ""
puts "Flame graph data saved to stackprof-wall.dump"
puts "View with: stackprof stackprof-wall.dump --text"
puts "Or:        stackprof stackprof-wall.dump --flamegraph > flame.html"
