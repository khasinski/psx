#!/usr/bin/env ruby
# frozen_string_literal: true

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)

require_relative "lib/psx"
require "stackprof"
require "benchmark"

bios_path = ARGV[0] || "SCPH1001.BIN"

puts "Profiling emulation with BIOS: #{bios_path}"
puts "YJIT: #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 'enabled' : 'disabled'}"

emu = PSX::Emulator.new(bios_path)

# Warm up
puts "Warming up..."
emu.run(steps: 500_000)

# Benchmark first
cycles = 5_000_000
puts "\nBenchmarking #{cycles / 1_000_000}M cycles..."
time = Benchmark.measure { emu.run(steps: cycles) }.real
cps = cycles / time
puts "Speed: #{(cps / 1_000_000).round(2)}M cycles/sec (#{(cps / 33_868_800 * 100).round(1)}% of real PS1)"

# Profile
puts "\nProfiling..."
profile = StackProf.run(mode: :wall, interval: 1000) do
  emu.run(steps: cycles)
end

StackProf::Report.new(profile).print_text(limit: 20)
