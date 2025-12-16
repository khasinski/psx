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
      def tick(cycles = 1)
        irq = false
        cycles.times do
          @counter += 1

          # Check target
          if @counter == @target && @target > 0
            @mode |= MODE_TARGET_REACHED
            if (@mode & MODE_IRQ_TARGET) != 0
              irq = true if !@irq_fired || (@mode & MODE_IRQ_REPEAT) != 0
            end
            @counter = 0 if (@mode & MODE_RESET_TARGET) != 0
          end

          # Check overflow
          if @counter > 0xFFFF
            @counter &= 0xFFFF
            @mode |= MODE_OVERFLOW
            if (@mode & MODE_IRQ_OVERFLOW) != 0
              irq = true if !@irq_fired || (@mode & MODE_IRQ_REPEAT) != 0
            end
          end
        end

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
      @system_counter += cycles

      # Timer 2 runs at system clock / 8
      timer2_ticks = @system_counter / 8
      if timer2_ticks > 0
        if @timers[2].tick(timer2_ticks)
          @interrupts&.request(Interrupts::IRQ_TIMER2)
        end
        @system_counter %= 8
      end

      # Timer 0 and 1 are typically synced to GPU
      # For simplicity, run them at a fixed rate
      if @timers[0].tick(cycles)
        @interrupts&.request(Interrupts::IRQ_TIMER0)
      end

      if @timers[1].tick(cycles / 8)  # Slower for hblank timing
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
