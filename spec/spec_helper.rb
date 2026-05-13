# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/psx"

# Test helper for creating minimal emulator setups
module TestHelpers
  def create_gpu
    PSX::GPU.new
  end

  def create_cpu_with_ram
    # Create a proper BIOS object with string data
    bios_data = "\x00" * 512 * 1024  # Empty BIOS
    bios = PSX::BIOS.allocate
    bios.instance_variable_set(:@data, bios_data)
    bios.instance_variable_set(:@words, Array.new(512 * 1024 / 4, 0))  # Pre-computed word array

    ram = PSX::RAM.new
    interrupts = PSX::Interrupts.new
    dma = PSX::DMA.new(interrupts: interrupts)
    timers = PSX::Timers.new(interrupts: interrupts)
    memory = PSX::Memory.new(bios: bios, ram: ram, interrupts: interrupts, dma: dma, timers: timers)

    cpu = PSX::CPU.new(memory, interrupts: interrupts)
    { cpu: cpu, memory: memory, ram: ram, interrupts: interrupts }
  end
end
