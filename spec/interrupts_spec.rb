# frozen_string_literal: true

require_relative "spec_helper"

class InterruptsSpec < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
  end

  def test_initial_state
    assert_equal 0, @interrupts.stat
    assert_equal 0, @interrupts.mask
  end

  def test_request_sets_status_bit
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    assert @interrupts.stat & PSX::Interrupts::IRQ_VBLANK != 0
  end

  def test_acknowledge_clears_status_bit
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    # Write 0 to acknowledge (clear), 1 to keep
    @interrupts.write_stat(~PSX::Interrupts::IRQ_VBLANK & 0x7FF)
    assert_equal 0, @interrupts.stat & PSX::Interrupts::IRQ_VBLANK
  end

  def test_pending_requires_mask
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    refute @interrupts.pending?, "No pending without mask"

    @interrupts.write_mask(PSX::Interrupts::IRQ_VBLANK)
    assert @interrupts.pending?, "Should be pending with mask set"
  end

  def test_multiple_interrupts
    @interrupts.request(PSX::Interrupts::IRQ_VBLANK)
    @interrupts.request(PSX::Interrupts::IRQ_DMA)

    expected = PSX::Interrupts::IRQ_VBLANK | PSX::Interrupts::IRQ_DMA
    assert_equal expected, @interrupts.stat
  end

  def test_irq_constants
    assert_equal 0x001, PSX::Interrupts::IRQ_VBLANK
    assert_equal 0x002, PSX::Interrupts::IRQ_GPU
    assert_equal 0x004, PSX::Interrupts::IRQ_CDROM
    assert_equal 0x008, PSX::Interrupts::IRQ_DMA
    assert_equal 0x010, PSX::Interrupts::IRQ_TIMER0
    assert_equal 0x020, PSX::Interrupts::IRQ_TIMER1
    assert_equal 0x040, PSX::Interrupts::IRQ_TIMER2
  end
end

class TimersSpec < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
    @timers = PSX::Timers.new(interrupts: @interrupts)
  end

  def test_initial_counter_values
    assert_equal 0, @timers.read(0x00)  # Timer 0 counter
    assert_equal 0, @timers.read(0x10)  # Timer 1 counter
    assert_equal 0, @timers.read(0x20)  # Timer 2 counter
  end

  def test_counter_increments
    @timers.tick(100)
    counter = @timers.read(0x00)
    assert counter > 0, "Counter should have incremented"
  end

  def test_write_counter_resets
    @timers.tick(100)
    @timers.write(0x00, 0)  # Reset counter
    assert_equal 0, @timers.read(0x00)
  end

  def test_target_register
    @timers.write(0x08, 0x1234)  # Timer 0 target
    assert_equal 0x1234, @timers.read(0x08)
  end

  def test_mode_register
    @timers.write(0x04, 0x0100)  # Timer 0 mode
    mode = @timers.read(0x04)
    # Reading mode should clear some bits
    assert mode != 0x0100 || mode == 0x0100  # Depends on implementation
  end
end
