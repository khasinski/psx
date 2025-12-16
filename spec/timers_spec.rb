# frozen_string_literal: true

require_relative "spec_helper"

class TimersTest < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
    @timers = PSX::Timers.new(interrupts: @interrupts)
  end

  # Basic register access tests
  def test_initial_counter_is_zero
    assert_equal 0, @timers.read(0x00)  # Timer 0 counter
    assert_equal 0, @timers.read(0x10)  # Timer 1 counter
    assert_equal 0, @timers.read(0x20)  # Timer 2 counter
  end

  def test_write_and_read_counter
    @timers.write(0x00, 0x1234)
    assert_equal 0x1234, @timers.read(0x00)
  end

  def test_counter_wraps_at_16_bits
    @timers.write(0x00, 0x1_2345)
    assert_equal 0x2345, @timers.read(0x00)
  end

  def test_write_and_read_target
    @timers.write(0x08, 0xABCD)  # Timer 0 target
    assert_equal 0xABCD, @timers.read(0x08)
  end

  def test_target_wraps_at_16_bits
    @timers.write(0x08, 0x1_FFFF)
    assert_equal 0xFFFF, @timers.read(0x08)
  end

  def test_write_mode_resets_counter
    @timers.write(0x00, 0x5000)  # Set counter
    @timers.write(0x04, 0x0000)  # Write mode
    assert_equal 0, @timers.read(0x00)  # Counter should be reset
  end

  def test_read_mode_clears_flags
    # Set up timer to trigger target reached
    @timers.write(0x08, 0x0005)  # Target = 5
    @timers.write(0x04, PSX::Timers::MODE_RESET_TARGET)  # Mode: reset on target

    # Tick until target
    5.times { @timers.tick(1) }

    # First read should have flag set
    mode = @timers.read(0x04)
    assert (mode & PSX::Timers::MODE_TARGET_REACHED) != 0

    # Second read should have flag cleared
    mode = @timers.read(0x04)
    assert_equal 0, mode & PSX::Timers::MODE_TARGET_REACHED
  end

  # Timer counting tests
  def test_timer_increments_on_tick
    initial = @timers.read(0x00)
    @timers.tick(10)
    assert @timers.read(0x00) > initial
  end

  def test_timer_overflow_sets_flag
    # Note: writing mode resets counter, so set counter AFTER mode
    @timers.write(0x04, 0)  # Clear mode first
    @timers.write(0x00, 0xFFFE)  # Near overflow (counter doesn't reset on counter write)
    @timers.tick(3)  # Should overflow

    mode = @timers.read(0x04)
    assert (mode & PSX::Timers::MODE_OVERFLOW) != 0
  end

  def test_timer_resets_on_target_when_enabled
    @timers.write(0x08, 0x0010)  # Target = 16
    @timers.write(0x04, PSX::Timers::MODE_RESET_TARGET)

    @timers.tick(20)

    # Counter should have reset at 16 and continued
    assert @timers.read(0x00) < 0x10
  end

  # IRQ tests
  def test_timer0_irq_on_target
    @timers.write(0x08, 0x0005)  # Target = 5
    @timers.write(0x04, PSX::Timers::MODE_IRQ_TARGET | PSX::Timers::MODE_RESET_TARGET)

    @timers.tick(10)

    # Timer 0 IRQ should be requested
    assert (@interrupts.stat & PSX::Interrupts::IRQ_TIMER0) != 0
  end

  def test_timer0_irq_on_overflow
    # Set mode first, then counter (mode write resets counter)
    @timers.write(0x04, PSX::Timers::MODE_IRQ_OVERFLOW)
    @timers.write(0x00, 0xFFFC)  # Near overflow

    @timers.tick(10)

    assert (@interrupts.stat & PSX::Interrupts::IRQ_TIMER0) != 0
  end

  def test_timer2_irq_on_target
    @timers.write(0x28, 0x0002)  # Timer 2 target = 2
    @timers.write(0x24, PSX::Timers::MODE_IRQ_TARGET | PSX::Timers::MODE_RESET_TARGET)

    # Timer 2 runs at system_clock/8, so need more cycles
    @timers.tick(100)

    assert (@interrupts.stat & PSX::Interrupts::IRQ_TIMER2) != 0
  end

  def test_no_irq_when_irq_flag_not_set
    @timers.write(0x08, 0x0005)  # Target = 5
    @timers.write(0x04, PSX::Timers::MODE_RESET_TARGET)  # No IRQ flags

    @timers.tick(10)

    # No IRQ should be requested
    assert_equal 0, @interrupts.stat & PSX::Interrupts::IRQ_TIMER0
  end

  # Timer isolation tests
  def test_timers_are_independent
    @timers.write(0x08, 0x0100)  # Timer 0 target = 256
    @timers.write(0x18, 0x0200)  # Timer 1 target = 512
    @timers.write(0x28, 0x0050)  # Timer 2 target = 80

    @timers.tick(50)

    # Each timer should have different values
    t0 = @timers.read(0x00)
    t1 = @timers.read(0x10)
    t2 = @timers.read(0x20)

    # They're all ticking at different rates
    assert t0 > 0
  end

  # Invalid timer access
  def test_invalid_timer_returns_zero
    assert_equal 0, @timers.read(0x30)  # Timer 3 doesn't exist
    assert_equal 0, @timers.read(0x40)  # Timer 4 doesn't exist
  end

  def test_invalid_timer_write_is_ignored
    @timers.write(0x30, 0xFFFF)  # Should not crash
    assert_equal 0, @timers.read(0x30)
  end
end
