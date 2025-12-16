# frozen_string_literal: true

require_relative "psx/bios"
require_relative "psx/ram"
require_relative "psx/cop0"
require_relative "psx/interrupts"
require_relative "psx/dma"
require_relative "psx/gpu"
require_relative "psx/timers"
require_relative "psx/memory"
require_relative "psx/cpu"
require_relative "psx/disasm"
require_relative "psx/display"

module PSX
  class Emulator
    attr_reader :cpu, :memory, :interrupts, :dma, :gpu, :timers

    # Timing constants
    CPU_FREQ = 33_868_800  # 33.8688 MHz
    CYCLES_PER_FRAME = CPU_FREQ / 60  # ~560K cycles per frame at 60Hz
    CYCLES_PER_SCANLINE = CYCLES_PER_FRAME / 263  # NTSC has 263 scanlines

    def initialize(bios_path)
      bios = BIOS.new(bios_path)
      ram = RAM.new
      @interrupts = Interrupts.new
      @dma = DMA.new(interrupts: @interrupts)
      @gpu = GPU.new(interrupts: @interrupts)
      @timers = Timers.new(interrupts: @interrupts)
      @memory = Memory.new(bios: bios, ram: ram, interrupts: @interrupts, dma: @dma, timers: @timers)
      @memory.gpu = @gpu
      @cpu = CPU.new(@memory, interrupts: @interrupts)

      @cycle_count = 0
      @frame_count = 0
    end

    def run(steps: nil, debug: false)
      count = 0
      loop do
        if debug
          puts @cpu.disassemble_current
          puts @cpu.dump_registers if count % 10 == 0
        end

        @cpu.step
        tick_devices

        count += 1
        break if steps && count >= steps
      end
    rescue CPU::ExecutionError => e
      puts "Execution error: #{e.message}"
      puts @cpu.dump_registers
      raise
    end

    # Run for specified number of frames
    def run_frames(frames)
      frames.times do |f|
        run(steps: CYCLES_PER_FRAME)
        @interrupts.request(Interrupts::IRQ_VBLANK)
        @frame_count += 1
      end
    end

    # Run with graphical display
    def run_with_display(target_fps: 60, frameskip: true)
      display = Display.new(title: "PSX-Ruby - Loading BIOS...")
      total_cycles = 0
      last_render = Time.now
      render_interval = 1.0 / 30  # Render at 30fps max

      # Run many cycles between renders for speed
      cycles_per_chunk = 500_000  # ~15ms of PS1 time per chunk

      puts "Starting emulation with display..."
      puts "Note: BIOS takes ~40 seconds to show Sony logo"
      puts "Controls: Arrow keys=D-pad, Z=Cross, X=Circle, A=Square, S=Triangle"
      puts "          Enter=Start, Space=Select, Q/W=L1/R1, Escape=Quit"
      puts ""

      loop do
        # Poll events
        display.poll_events
        break if display.quit_requested?

        # Run a chunk of emulation (no VBlank interrupts - they break BIOS)
        begin
          run(steps: cycles_per_chunk)
          total_cycles += cycles_per_chunk
        rescue CPU::ExecutionError => e
          puts "CPU Error: #{e.message}"
          puts @cpu.dump_registers
          display.close
          return
        end

        # Render periodically
        now = Time.now
        if now - last_render >= render_interval
          @gpu.vblank
          @frame_count += 1
          display.update(@gpu.framebuffer)
          last_render = now
        end
      end

      display.close
      puts "\nEmulation ended after #{@frame_count} frames (#{total_cycles} cycles)"
    end

    # Save framebuffer as PPM image
    def save_screenshot(filename)
      fb = @gpu.framebuffer
      File.open(filename, "wb") do |f|
        f.puts "P6"
        f.puts "#{fb[:width]} #{fb[:height]}"
        f.puts "255"
        f.write fb[:pixels].pack("C*")
      end
      puts "Saved screenshot to #{filename} (#{fb[:width]}x#{fb[:height]})"
    end

    # Save framebuffer as ASCII art (for terminal)
    def ascii_screenshot(width: 80)
      fb = @gpu.framebuffer
      scale_x = fb[:width].to_f / width
      height = (fb[:height] / scale_x / 2).to_i  # /2 because terminal chars are ~2x tall

      chars = " .:-=+*#%@"

      lines = []
      height.times do |y|
        line = +""  # Unfrozen string
        width.times do |x|
          src_x = (x * scale_x).to_i
          src_y = (y * scale_x * 2).to_i
          idx = (src_y * fb[:width] + src_x) * 3
          r = fb[:pixels][idx] || 0
          g = fb[:pixels][idx + 1] || 0
          b = fb[:pixels][idx + 2] || 0
          brightness = (r + g + b) / 3.0 / 255.0
          char_idx = (brightness * (chars.length - 1)).to_i
          line << chars[char_idx]
        end
        lines << line
      end
      lines.join("\n")
    end

    private

    def tick_devices
      @cycle_count += 1

      # Tick timers less frequently for performance
      if @cycle_count % 64 == 0
        @timers.tick(64)
      end

      # VBlank every frame
      if @cycle_count >= CYCLES_PER_FRAME
        @cycle_count = 0
        @frame_count += 1
        @interrupts.request(Interrupts::IRQ_VBLANK)
        @gpu.vblank  # Toggle interlace field
      end
    end
  end
end
