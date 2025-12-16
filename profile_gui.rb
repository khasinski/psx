#!/usr/bin/env ruby
# frozen_string_literal: true

# Profile the GUI rendering to find bottlenecks

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)

require_relative "lib/psx"
require "benchmark"

# Create a mock framebuffer with RGBA content (new format)
width = 320
height = 240
# Generate random RGBA data as packed string
rgba_arr = Array.new(width * height * 4) { rand(256) }
rgba = rgba_arr.pack("C*")
framebuffer = { width: width, height: height, rgba: rgba }

# Initialize display
display = PSX::Display.new(title: "Profiling...")
display.instance_variable_set(:@has_rendered_content, true)  # Skip content check

# Time different parts
iterations = 100

puts "Profiling Display#update (OPTIMIZED - RGBA) with #{iterations} iterations..."
puts ""

# Profile full update
total_time = Benchmark.measure {
  iterations.times { display.update(framebuffer) }
}.real

puts "Full update: #{(total_time / iterations * 1000).round(2)}ms per frame"
puts "Achievable FPS: #{(iterations / total_time).round(1)}"

# Also profile GPU.framebuffer
puts ""
puts "Profiling GPU.framebuffer generation..."
gpu = PSX::GPU.new
# Simulate some VRAM content
gpu.vram.fill(0x7FFF, 0, 1000)

# First call always generates
gpu_first_time = Benchmark.measure { gpu.framebuffer }.real
puts "GPU.framebuffer (first): #{(gpu_first_time * 1000).round(2)}ms"

# Subsequent calls without dirty should be cached
gpu_cached_time = Benchmark.measure {
  iterations.times { gpu.framebuffer }
}.real
puts "GPU.framebuffer (cached, #{iterations}x): #{(gpu_cached_time / iterations * 1000).round(4)}ms per call"

# With dirty flag (simulating actual drawing)
gpu_dirty_time = Benchmark.measure {
  iterations.times do
    gpu.mark_dirty
    gpu.framebuffer
  end
}.real
puts "GPU.framebuffer (dirty each time): #{(gpu_dirty_time / iterations * 1000).round(2)}ms per frame"

# Realistic scenario: only mark dirty sometimes (e.g., 10% of frames have changes)
dirty_rate = 0.1
gpu_realistic_time = Benchmark.measure {
  iterations.times do |i|
    gpu.mark_dirty if rand < dirty_rate
    gpu.framebuffer
  end
}.real
puts "GPU.framebuffer (#{(dirty_rate * 100).to_i}% dirty): #{(gpu_realistic_time / iterations * 1000).round(2)}ms per frame"

puts ""
puts "Combined with Display (realistic): #{((gpu_realistic_time + total_time) / iterations * 1000).round(2)}ms"
puts "Combined FPS (realistic): #{(iterations / (gpu_realistic_time + total_time)).round(1)}"

begin
  display.send(:close) rescue nil
rescue
  # Ignore SDL2.quit error
end
