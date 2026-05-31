# frozen_string_literal: true

require_relative "psx/version"
require_relative "psx/bios"
require_relative "psx/ram"
require_relative "psx/cop0"
require_relative "psx/interrupts"
require_relative "psx/dma"
require_relative "psx/gpu"
require_relative "psx/timers"
require_relative "psx/disc"
require_relative "psx/iso9660"
require_relative "psx/cdrom"
require_relative "psx/sio0"
require_relative "psx/spu"
require_relative "psx/mdec"
require_relative "psx/memory"
require_relative "psx/cpu"
require_relative "psx/disasm"
require_relative "psx/display"
require_relative "psx/audio"
require_relative "psx/savestate"

module PSX
  class Emulator
    attr_reader :bios, :cpu, :memory, :interrupts, :dma, :gpu, :timers, :cdrom, :sio0, :spu, :mdec
    attr_accessor :controller_state_proc

    # Timing constants
    CPU_FREQ = 33_868_800  # 33.8688 MHz
    CYCLES_PER_FRAME = CPU_FREQ / 60  # ~560K cycles per frame at 60Hz
    CYCLES_PER_SCANLINE = CYCLES_PER_FRAME / 263  # NTSC has 263 scanlines

    def initialize(bios_path, disc_path: nil, fast_boot: false)
      @bios = BIOS.new(bios_path, fast_boot: fast_boot)
      ram = RAM.new
      @interrupts = Interrupts.new
      @spu = SPU.new(interrupts: @interrupts)
      @mdec = MDEC.new
      disc = disc_path ? Disc.open(disc_path) : nil
      @cdrom = CDROM.new(interrupts: @interrupts, disc: disc)
      @dma = DMA.new(interrupts: @interrupts, spu: @spu, cdrom: @cdrom, mdec: @mdec)
      @gpu = GPU.new(interrupts: @interrupts)
      @timers = Timers.new(interrupts: @interrupts)
      @controller_state_proc = -> { 0xFFFF }
      @sio0 = SIO0.new(interrupts: @interrupts, controller_state: -> { @controller_state_proc.call })
      @memory = Memory.new(
        bios: @bios, ram: ram, interrupts: @interrupts,
        dma: @dma, timers: @timers, cdrom: @cdrom, sio0: @sio0, spu: @spu, mdec: @mdec
      )
      @memory.gpu = @gpu
      @dma.memory = @memory  # so tick_cycles can retry deferred CDROM transfers
      @cpu = CPU.new(@memory, interrupts: @interrupts)

      @cycle_count = 0
      @frame_count = 0
    end

    # Insert (or eject, with nil) a disc after construction.
    def load_disc(path)
      @cdrom.disc = path ? Disc.open(path) : nil
    end

    # Open the host audio device (44.1 kHz S16LE stereo) and wire the
    # CDROM to push CDDA sectors into it. No-op if audio init fails —
    # the emulator still runs, just silent. Idempotent.
    def enable_cdda_audio!
      return if @audio_dev
      SDL2.init(SDL2::INIT_AUDIO) if defined?(SDL2)
      @audio_dev = Audio.open_device(freq: 44_100, channels: 2)
      if @audio_dev
        @cdrom.cdda_sink = ->(bytes) { @spu.queue_cd_audio(bytes) }
        @cdrom.xa_adpcm_sink = ->(bytes) { @spu.queue_cd_audio(bytes) }
        @spu.pcm_sink = ->(bytes) { Audio.queue(@audio_dev, bytes) }
      else
        warn "Audio: failed to open device, running silent"
      end
    end

    # Fast-boot: get a PS-EXE running on top of the BIOS without making the
    # user sit through the Sony splash. Two strategies, picked at runtime:
    #
    # 1. Retail disc with a valid Sony license image. The BIOS bootstrap
    #    loader will reach "Execute !" all on its own and call Exec(),
    #    which sets up the kernel's CD callbacks and event hooks before
    #    handing control to the disc's PS-EXE. We just run the BIOS in
    #    chunks until that marker hits the TTY, then return -- the BIOS
    #    has already done everything load_psexe would do, but with the
    #    full kernel state the disc expects.
    #
    # 2. Synthetic / homebrew disc with no license image. The BIOS won't
    #    boot it, so "Execute !" never appears. We fall back to running
    #    `boot_cycles` of BIOS init and then manually loading the EXE.
    #    Kernel state is bare, but homebrew tests (amidog, ps1-tests,
    #    PCSX-Redux demos) don't use the BIOS kernel CD library anyway.
    #
    # Returns the parsed BOOT path from SYSTEM.CNF for diagnostics.
    def fast_boot_from_disc(boot_cycles: 6_000_000, max_bios_cycles: 300_000_000)
      raise "no disc loaded" unless @cdrom.disc

      iso = ISO9660.new(@cdrom.disc)
      cnf = iso.read_file("SYSTEM.CNF")
      m = cnf.match(/^BOOT\s*=\s*cdrom:[\\\/]*(\S+?)(?:;\d+)?\s*$/m) ||
          cnf.match(/^BOOT\s*=\s*([^\r\n]+?)(?:;\d+)?\s*$/m)
      raise "SYSTEM.CNF has no BOOT= line: #{cnf.inspect}" unless m
      exe_path = m[1].strip.sub(/\Acdrom:/i, "")
      exe_bytes = iso.read_file(exe_path)

      # Watch TTY for the bootstrap loader's "Execute !" marker.
      saw_execute = false
      tty_buf = +""
      orig_handler = @cpu.tty_handler
      @cpu.tty_handler = ->(kind, val) do
        s = (kind == :char ? val.chr : val.to_s)
        tty_buf << s
        saw_execute ||= tty_buf.include?("Execute !")
        orig_handler&.call(kind, val)
      end

      cycles_run = 0
      if retail_bios_boot_possible?
        chunk = 1_000_000
        while cycles_run < max_bios_cycles && !saw_execute
          step = [chunk, max_bios_cycles - cycles_run].min
          run(steps: step)
          cycles_run += step
        end
      end
      @cpu.tty_handler = orig_handler

      if saw_execute
        # BIOS reached Exec(); it has set up the kernel CD events and is
        # about to jump to the disc's PS-EXE. Nothing more to do.
        return exe_path
      end

      # No license image (or BIOS gave up before max_bios_cycles).
      # Top up to at least boot_cycles, then inject the EXE manually.
      if cycles_run < boot_cycles
        run(steps: boot_cycles - cycles_run)
      end
      load_psexe(exe_bytes)
      exe_path
    end

    def retail_bios_boot_possible?
      bios_region = @bios.region_code
      disc = @cdrom.disc
      disc_region = disc.region_code if disc&.respond_to?(:region_code)
      return true if bios_region.nil? || disc_region.nil?

      bios_region == disc_region
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

    # Fast path for Ruby CPU: known number of steps, no debug.
    # Two-level loop: the inner loop is kept tight (step + accumulate
    # cycles) so YJIT can compile a small specialized loop body. The
    # outer loop runs every ~64 cycles to do the heavier bookkeeping
    # (device ticks, frame/VBlank). Device timing matches the previous
    # single-loop version because both batched at the same 64-cycle
    # cadence; the outer cadence is in [64, 64+step_cycles_max] cycles.
    def run_fast(steps)
      cpu = @cpu
      cycle_count = @cycle_count
      frame_count = @frame_count
      timers = @timers
      interrupts = @interrupts
      gpu = @gpu
      spu = @spu
      remaining = steps

      sio0 = @sio0
      dma = @dma
      cdrom = @cdrom
      while remaining > 0
        batch_cycles = 0
        while batch_cycles < 64 && remaining > 0
          remaining -= 1
          batch_cycles += cpu.step
        end

        cycle_count += batch_cycles
        timers.tick(batch_cycles)
        sio0.tick(batch_cycles)
        dma.tick_cycles(batch_cycles)
        cdrom.tick(batch_cycles)
        mdec.tick(batch_cycles)
        spu.tick(batch_cycles)
        cpu.check_interrupts
        refresh_bios_pad_buffers

        if cycle_count >= CYCLES_PER_FRAME
          cycle_count = 0
          frame_count += 1
          interrupts.request(Interrupts::IRQ_VBLANK)
          gpu.vblank
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

      # Audio output. Failure is non-fatal — we just run silent if no
      # audio device is available. CDDA samples are 44.1 kHz S16LE stereo,
      # which is exactly what SDL queues without resampling.
      enable_cdda_audio!

      # Run many cycles between renders for speed
      cycles_per_chunk = 100_000  # Smaller chunks for better responsiveness

      puts "Starting emulation with display (threaded)..."
      puts "Note: BIOS takes ~40 seconds to show Sony logo"
      puts "Controls: Arrow keys=D-pad, Z=Cross, X=Circle, A=Square, S=Triangle"
      puts "          Enter=Start, Space=Select, Q/W=L1/R1, Escape=Quit"
      puts "          F5=quicksave, F6=state+screenshot, F8=quickload"
      puts "          PSX_QUICKSAVE / PSX_DEBUG_SNAPSHOT env vars control output paths"
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
      quicksave_path = ENV["PSX_QUICKSAVE"] || "tmp/quicksave.psxstate"
      debug_snapshot_prefix = ENV["PSX_DEBUG_SNAPSHOT"] || "tmp/debug-snapshot"
      require "fileutils"
      FileUtils.mkdir_p(File.dirname(quicksave_path))
      FileUtils.mkdir_p(File.dirname(debug_snapshot_prefix))

      loop do
        # Poll SDL events (must be on main thread on macOS)
        display.poll_events
        if display.quit_requested?
          @quit_flag = true
          break
        end

        # F5 save / F8 load — done with the emulation mutex held so the
        # snapshot is taken between CPU steps, not mid-instruction.
        if display.take_save_request!
          @emu_mutex.synchronize do
            save_state(quicksave_path)
            display.flash_status("Saved -> #{quicksave_path}")
            puts "[savestate] saved to #{quicksave_path} (PC=#{format('0x%08X', @cpu.pc)})"
          end
        end
        if display.take_load_request!
          if File.exist?(quicksave_path)
            @emu_mutex.synchronize do
              load_state(quicksave_path)
              display.flash_status("Loaded <- #{quicksave_path}")
              puts "[savestate] loaded from #{quicksave_path} (PC=#{format('0x%08X', @cpu.pc)})"
            end
          else
            display.flash_status("No save at #{quicksave_path}")
            puts "[savestate] no file at #{quicksave_path}"
          end
        end
        if display.take_debug_snapshot_request!
          @emu_mutex.synchronize do
            paths = save_debug_snapshot(debug_snapshot_prefix)
            display.flash_status("Snapshot -> #{paths[:state]}")
            puts "[snapshot] saved state=#{paths[:state]} screenshot=#{paths[:screenshot]} " \
                 "(PC=#{format('0x%08X', @cpu.pc)})"
          end
        end

        # Check for emulation errors
        if @emu_error
          puts "CPU Error: #{@emu_error.message}"
          @emu_mutex.synchronize { puts @cpu.dump_registers }
          @quit_flag = true
          break
        end

        # Render at target FPS. Important: do NOT toggle @gpu.vblank here.
        # The emulator's run loop is the authoritative driver of vblank
        # (CYCLES_PER_FRAME boundaries). Toggling here at wall-clock 60 Hz on
        # top of that confuses BIOS-side vsync counters and trips
        # SystemErrorUnresolvedException.
        now = Time.now
        elapsed = now - last_render
        if elapsed >= render_interval
          @emu_mutex.synchronize do
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

    def save_debug_snapshot(prefix)
      require "fileutils"
      dir = File.dirname(prefix)
      FileUtils.mkdir_p(dir) unless dir == "."
      state_path = "#{prefix}.psxstate"
      screenshot_path = "#{prefix}.ppm"

      save_state(state_path)
      save_screenshot(screenshot_path)

      { state: state_path, screenshot: screenshot_path }
    end

    # Load a PS-EXE executable into RAM and prepare the CPU to run it.
    # Standard PSX EXE format: 2048-byte header (magic "PS-X EXE"), followed
    # by the text/data section that must be copied to dest_addr. After load
    # the CPU is positioned at the executable's entry point with GP and SP
    # set per the header (or the conventional defaults if zero).
    #
    # `source` may be a filesystem path or an already-loaded binary string
    # (e.g. EXE bytes read from a disc image).
    def load_psexe(source)
      data = source.is_a?(String) && source.bytesize >= 8 && source.byteslice(0, 8) == "PS-X EXE" ? source : File.binread(source)
      raise "PS-EXE smaller than header: #{data.bytesize} bytes" if data.bytesize < 0x800
      magic = data.byteslice(0, 8)
      raise "Not a PS-EXE (magic=#{magic.inspect})" unless magic == "PS-X EXE"

      initial_pc    = data.byteslice(0x10, 4).unpack1("V")
      initial_gp    = data.byteslice(0x14, 4).unpack1("V")
      dest_addr     = data.byteslice(0x18, 4).unpack1("V")
      file_size     = data.byteslice(0x1C, 4).unpack1("V")
      memfill_start = data.byteslice(0x20, 4).unpack1("V")
      memfill_size  = data.byteslice(0x24, 4).unpack1("V")
      stack_addr    = data.byteslice(0x28, 4).unpack1("V")
      _stack_size   = data.byteslice(0x2C, 4).unpack1("V")

      payload = data.byteslice(0x800, file_size) || ""
      payload.each_byte.with_index do |b, i|
        @memory.write8((dest_addr + i) & 0xFFFF_FFFF, b)
      end

      if memfill_size.positive?
        memfill_size.times do |i|
          @memory.write8((memfill_start + i) & 0xFFFF_FFFF, 0)
        end
      end

      sp = stack_addr.zero? ? 0x801F_FFF0 : stack_addr
      @cpu.regs[28] = initial_gp & 0xFFFF_FFFF
      @cpu.regs[29] = sp & 0xFFFF_FFFF
      @cpu.regs[30] = sp & 0xFFFF_FFFF
      @cpu.regs[31] = 0 # return-to-zero on exit
      @cpu.pc = initial_pc

      {
        entry: initial_pc, gp: initial_gp, sp: sp, dest: dest_addr,
        size: file_size, memfill: [memfill_start, memfill_size]
      }
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

    BIOS_PAD1_BUFFER_PTR = 0x8000_74C8
    BIOS_PAD2_BUFFER_PTR = 0x8000_74CC
    BIOS_PAD1_BUFFER_LEN = 0x8000_74D8
    BIOS_PAD2_BUFFER_LEN = 0x8000_74DC

    def refresh_bios_pad_buffers
      refresh_bios_pad1_buffer
      refresh_bios_pad2_buffer
    end

    def refresh_bios_pad1_buffer
      addr = @memory.read32(BIOS_PAD1_BUFFER_PTR)
      length = @memory.read32(BIOS_PAD1_BUFFER_LEN)
      return unless bios_pad_buffer?(addr, length)

      state = @controller_state_proc.call & 0xFFFF
      @memory.write8(addr, 0x00)
      @memory.write8(addr + 1, SIO0::DIGITAL_PAD_IDHI)
      @memory.write8(addr + 2, state & 0xFF)
      @memory.write8(addr + 3, (state >> 8) & 0xFF)
    rescue StandardError
      # Treat host input failures as no pad state change.
    end

    def refresh_bios_pad2_buffer
      addr = @memory.read32(BIOS_PAD2_BUFFER_PTR)
      length = @memory.read32(BIOS_PAD2_BUFFER_LEN)
      return unless bios_pad_buffer?(addr, length)

      @memory.write8(addr, 0xFF)
      @memory.write8(addr + 1, 0x00)
      @memory.write8(addr + 2, 0x00)
      @memory.write8(addr + 3, 0x00)
    end

    def bios_pad_buffer?(addr, length)
      return false if addr.zero? || length < 4

      phys = addr & Memory::REGION_MASK[(addr >> 29) & 0x7]
      phys < Memory::RAM_SIZE && phys + 3 < Memory::RAM_SIZE
    end

    def tick_devices
      @cycle_count += 1

      # Tick timers less frequently for performance
      if @cycle_count % 64 == 0
        @timers.tick(64)
        @sio0.tick(64)
        @dma.tick_cycles(64)
        @cdrom.tick(64)
        @mdec.tick(64)
        @spu.tick(64)
      end

      # VBlank every frame
      if @cycle_count >= CYCLES_PER_FRAME
        @cycle_count = 0
        @frame_count += 1
        @interrupts.request(Interrupts::IRQ_VBLANK)
        @gpu.vblank  # Toggle interlace field
      end
      refresh_bios_pad_buffers
    end
  end
end
