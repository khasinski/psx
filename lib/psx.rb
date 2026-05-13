# frozen_string_literal: true

require_relative "psx/bios"
require_relative "psx/ram"
require_relative "psx/cop0"
require_relative "psx/interrupts"
require_relative "psx/dma"
require_relative "psx/gpu"
require_relative "psx/timers"
require_relative "psx/cdrom"
require_relative "psx/sio0"
require_relative "psx/memory"
require_relative "psx/cpu"
require_relative "psx/disasm"
require_relative "psx/display"

module PSX
  class Emulator
    attr_reader :cpu, :memory, :interrupts, :dma, :gpu, :timers, :cdrom, :sio0
    attr_accessor :controller_state_proc

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
      @cdrom = CDROM.new(interrupts: @interrupts)
      @controller_state_proc = -> { 0xFFFF }
      @sio0 = SIO0.new(interrupts: @interrupts, controller_state: -> { @controller_state_proc.call })
      @memory = Memory.new(
        bios: bios, ram: ram, interrupts: @interrupts,
        dma: @dma, timers: @timers, cdrom: @cdrom, sio0: @sio0
      )
      @memory.gpu = @gpu
      @cpu = CPU.new(@memory, interrupts: @interrupts)

      @cycle_count = 0
      @frame_count = 0
    end

    def run(steps: nil, debug: false)
      if debug
        run_debug(steps)
      elsif steps
        run_fast(steps)
      else
        run_forever
      end
    rescue CPU::ExecutionError => e
      puts "Execution error: #{e.message}"
      puts @cpu.dump_registers
      raise
    end

    # Fast path for Ruby CPU: known number of steps, no debug
    def run_fast(steps)
      cpu = @cpu
      cycle_count = @cycle_count
      frame_count = @frame_count
      timers = @timers
      interrupts = @interrupts
      gpu = @gpu
      remaining = steps

      sio0 = @sio0
      while remaining > 0
        remaining -= 1
        cpu.step

        # Inlined tick_devices
        cycle_count += 1
        if cycle_count & 63 == 0  # % 64 as bitmask
          timers.tick(64)
          sio0.tick(64)
        end
        if cycle_count >= CYCLES_PER_FRAME
          cycle_count = 0
          frame_count += 1
          interrupts.request(Interrupts::IRQ_VBLANK)
          gpu.vblank
          @cdrom.tick
        end
      end

      @cycle_count = cycle_count
      @frame_count = frame_count
    end

    def run_forever
      loop do
        @cpu.step
        tick_devices
      end
    end

    def run_debug(steps)
      count = 0
      loop do
        puts @cpu.disassemble_current
        puts @cpu.dump_registers if count % 10 == 0
        @cpu.step
        tick_devices
        count += 1
        break if steps && count >= steps
      end
    end

    # Run for specified number of frames
    def run_frames(frames)
      frames.times do |f|
        run(steps: CYCLES_PER_FRAME)
        @interrupts.request(Interrupts::IRQ_VBLANK)
        @frame_count += 1
      end
    end

    # Run with graphical display (threaded: emulation in background)
    def run_with_display(target_fps: 60, frameskip: true)
      display = Display.new(title: "PSX-Ruby - Loading BIOS...")
      @controller_state_proc = -> { display.controller_state }
      render_interval = 1.0 / target_fps

      # Run many cycles between renders for speed
      cycles_per_chunk = 100_000  # Smaller chunks for better responsiveness

      puts "Starting emulation with display (threaded)..."
      puts "Note: BIOS takes ~40 seconds to show Sony logo"
      puts "Controls: Arrow keys=D-pad, Z=Cross, X=Circle, A=Square, S=Triangle"
      puts "          Enter=Start, Space=Select, Q/W=L1/R1, Escape=Quit"
      puts ""

      # Shared state
      @emu_mutex = Mutex.new
      @quit_flag = false
      @emu_error = nil
      @total_cycles = 0

      # Emulation thread
      emu_thread = Thread.new do
        loop do
          break if @quit_flag

          begin
            @emu_mutex.synchronize do
              run(steps: cycles_per_chunk)
              @total_cycles += cycles_per_chunk
            end
          rescue CPU::ExecutionError => e
            @emu_error = e
            break
          end

          # Small yield to let main thread get lock
          Thread.pass if @total_cycles % 500_000 == 0
        end
      end

      # Main thread: SDL events and rendering
      last_render = Time.now
      last_status = Time.now
      last_status_cycles = 0
      loop do
        # Poll SDL events (must be on main thread on macOS)
        display.poll_events
        if display.quit_requested?
          @quit_flag = true
          break
        end

        # Check for emulation errors
        if @emu_error
          puts "CPU Error: #{@emu_error.message}"
          @emu_mutex.synchronize { puts @cpu.dump_registers }
          @quit_flag = true
          break
        end

        # Render at target FPS
        now = Time.now
        elapsed = now - last_render
        if elapsed >= render_interval
          @emu_mutex.synchronize do
            @gpu.vblank
            @frame_count += 1
            display.update(@gpu.framebuffer)
          end
          last_render = now
        else
          # Sleep for remaining time to hit target FPS
          sleep_time = render_interval - elapsed
          sleep(sleep_time * 0.8) if sleep_time > 0.001  # Don't oversleep
        end

        # Periodic status line so progress is visible from the console.
        if now - last_status >= 2.0
          delta = @total_cycles - last_status_cycles
          ips = delta.to_f / (now - last_status)
          printf "frames=%5d  cycles=%10d  %.1f Mips  PC=%08X\n",
                 @frame_count, @total_cycles, ips / 1_000_000.0, @cpu.pc
          $stdout.flush
          last_status = now
          last_status_cycles = @total_cycles
        end
      end

      # Wait for emulation thread to finish
      emu_thread.join(1.0)  # Wait up to 1 second

      display.close
      puts "\nEmulation ended after #{@frame_count} frames (#{@total_cycles} cycles)"
    end

    # Save framebuffer as PPM image
    def save_screenshot(filename)
      fb = @gpu.framebuffer
      rgba = fb[:rgba]
      width = fb[:width]
      height = fb[:height]

      # Extract RGB from RGBA (skip alpha bytes)
      rgb_data = String.new(capacity: width * height * 3)
      i = 0
      (width * height).times do
        rgb_data << rgba.getbyte(i).chr << rgba.getbyte(i + 1).chr << rgba.getbyte(i + 2).chr
        i += 4
      end

      File.open(filename, "wb") do |f|
        f.puts "P6"
        f.puts "#{width} #{height}"
        f.puts "255"
        f.write rgb_data
      end
      puts "Saved screenshot to #{filename} (#{width}x#{height})"
    end

    # Save framebuffer as ASCII art (for terminal)
    def ascii_screenshot(width: 80)
      fb = @gpu.framebuffer
      rgba = fb[:rgba]
      scale_x = fb[:width].to_f / width
      height = (fb[:height] / scale_x / 2).to_i  # /2 because terminal chars are ~2x tall

      chars = " .:-=+*#%@"

      lines = []
      height.times do |y|
        line = +""  # Unfrozen string
        width.times do |x|
          src_x = (x * scale_x).to_i
          src_y = (y * scale_x * 2).to_i
          # RGBA format: 4 bytes per pixel
          idx = (src_y * fb[:width] + src_x) * 4
          r = rgba.getbyte(idx) || 0
          g = rgba.getbyte(idx + 1) || 0
          b = rgba.getbyte(idx + 2) || 0
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
        @sio0.tick(64)
      end

      # VBlank every frame
      if @cycle_count >= CYCLES_PER_FRAME
        @cycle_count = 0
        @frame_count += 1
        @interrupts.request(Interrupts::IRQ_VBLANK)
        @gpu.vblank  # Toggle interlace field
        @cdrom.tick
      end
    end
  end
end
