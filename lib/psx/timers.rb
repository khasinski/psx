# frozen_string_literal: true

module PSX
  # Root Counters (Timers)
  # Timer 0: Pixel clock / Dot clock
  # Timer 1: Horizontal retrace
  # Timer 2: System clock / 8
  class Timers
    NUM_TIMERS = 3

    # Mode register bits
    MODE_SYNC_ENABLE  = 0x0001  # Sync enable
    MODE_SYNC_MODE    = 0x0006  # Sync mode (bits 1-2)
    MODE_RESET_TARGET = 0x0008  # Reset counter on target
    MODE_IRQ_TARGET   = 0x0010  # IRQ when target reached
    MODE_IRQ_OVERFLOW = 0x0020  # IRQ on overflow
    MODE_IRQ_REPEAT   = 0x0040  # Repeat IRQ
    MODE_IRQ_TOGGLE   = 0x0080  # Toggle IRQ bit
    MODE_CLOCK_SOURCE = 0x0300  # Clock source (bits 8-9)
    MODE_IRQ_FLAG     = 0x0400  # IRQ flag (bit 10, read-only)
    MODE_TARGET_REACHED = 0x0800 # Target reached (bit 11)
    MODE_OVERFLOW     = 0x1000  # Overflow occurred (bit 12)

    class Timer
      attr_accessor :counter, :mode, :target

      def initialize
        @counter = 0
        @mode = 0
        @target = 0
        @irq_fired = false
      end

      def read_counter
        @counter
      end

      def write_counter(value)
        @counter = value & 0xFFFF
      end

      def read_mode
        # Return mode and clear flags
        result = @mode
        @mode &= ~(MODE_TARGET_REACHED | MODE_OVERFLOW)
        result
      end

      def write_mode(value)
        @mode = value & 0x03FF  # Writable bits
        @counter = 0  # Writing to mode resets counter
        @irq_fired = false
      end

      def read_target
        @target
      end

      def write_target(value)
        @target = value & 0xFFFF
      end

      # Increment counter, returns true if IRQ should fire
      # Optimized to avoid per-cycle loop
      def tick(cycles = 1)
        return false if cycles <= 0

        irq = false
        new_counter = @counter + cycles

        # Check for target hit (if target is set and reset-on-target is enabled)
        if @target > 0 && (@mode & MODE_RESET_TARGET) != 0
          # Will we cross the target?
          if @counter < @target && new_counter >= @target
            @mode |= MODE_TARGET_REACHED
            if (@mode & MODE_IRQ_TARGET) != 0
              irq = true if !@irq_fired || (@mode & MODE_IRQ_REPEAT) != 0
            end
            # Reset and continue counting from target
            new_counter = (new_counter - @target) % (@target > 0 ? @target : 0x10000)
          end
        elsif @target > 0 && @counter < @target && new_counter >= @target
          # Target without reset - just set flag
          @mode |= MODE_TARGET_REACHED
          if (@mode & MODE_IRQ_TARGET) != 0
            irq = true if !@irq_fired || (@mode & MODE_IRQ_REPEAT) != 0
          end
        end

        # Check for overflow
        if new_counter > 0xFFFF
          @mode |= MODE_OVERFLOW
          if (@mode & MODE_IRQ_OVERFLOW) != 0
            irq = true if !@irq_fired || (@mode & MODE_IRQ_REPEAT) != 0
          end
          new_counter &= 0xFFFF
        end

        @counter = new_counter
        @irq_fired = true if irq && (@mode & MODE_IRQ_REPEAT) == 0
        irq
      end
    end

    def initialize(interrupts: nil)
      @interrupts = interrupts
      @timers = Array.new(NUM_TIMERS) { Timer.new }
      @system_counter = 0
    end

    def read(offset)
      timer_num = offset / 0x10
      reg = offset % 0x10

      return 0 if timer_num >= NUM_TIMERS

      timer = @timers[timer_num]
      case reg
      when 0x00 then timer.read_counter
      when 0x04 then timer.read_mode
      when 0x08 then timer.read_target
      else 0
      end
    end

    def write(offset, value)
      timer_num = offset / 0x10
      reg = offset % 0x10

      return if timer_num >= NUM_TIMERS

      timer = @timers[timer_num]
      case reg
      when 0x00 then timer.write_counter(value)
      when 0x04 then timer.write_mode(value)
      when 0x08 then timer.write_target(value)
      end
    end

    # Call this periodically to advance timers
    # cycles: number of CPU cycles elapsed
    def tick(cycles = 1)
      # Timer 2 clock source (mode bits 9..8): 0/1 = sysclock, 2/3 = sysclock/8.
      # amidog's psxtest_gte TIMING column puts Timer 2 in raw sysclock mode
      # so it can read per-instruction-grain deltas around GTE ops.
      t2_src = (@timers[2].mode >> 8) & 3
      if t2_src >= 2
        @system_counter += cycles
        timer2_ticks = @system_counter / 8
        if timer2_ticks > 0
          if @timers[2].tick(timer2_ticks)
            @interrupts&.request(Interrupts::IRQ_TIMER2)
          end
          @system_counter %= 8
        end
      else
        if @timers[2].tick(cycles)
          @interrupts&.request(Interrupts::IRQ_TIMER2)
        end
      end

      # Timer 0 / Timer 1 — sysclock when src is 0 or 2, otherwise dot/hblank.
      # We have no real dot/hblank source, so for dotclock fall back to sysclock
      # and for hblank approximate at sysclock/8 (the prior behaviour).
      t0_src = (@timers[0].mode >> 8) & 3
      if @timers[0].tick(cycles)  # both sysclock and dotclock paths tick on cycles for now
        @interrupts&.request(Interrupts::IRQ_TIMER0)
      end

      t1_src = (@timers[1].mode >> 8) & 3
      t1_cycles = (t1_src.odd?) ? cycles / 8 : cycles
      if @timers[1].tick(t1_cycles)
        @interrupts&.request(Interrupts::IRQ_TIMER1)
      end
    end

    # Call on VBlank to update timer 1
    def vblank
      # Timer 1 often syncs to vblank
    end

    # Call on HBlank
    def hblank
      # Timer 0 and 1 can sync to hblank
    end
  end
end
