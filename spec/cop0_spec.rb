# frozen_string_literal: true

require_relative "spec_helper"

class COP0Test < Minitest::Test
  def setup
    @cop0 = PSX::COP0.new
  end

  # Register read/write tests
  def test_initial_state
    assert_equal 0x0000_0002, @cop0.read(PSX::COP0::PRID), "PRID should be R3000A ID"
    assert_equal 0, @cop0.sr
    assert_equal 0, @cop0.cause
    assert_equal 0, @cop0.epc
  end

  def test_status_register_writable
    @cop0.sr = 0xFFFF_FFFF
    # Only certain bits are writable
    assert_equal 0xF4C7_9C3F & 0xFFFF_FFFF, @cop0.sr
  end

  def test_cause_register_only_software_irq_writable
    @cop0.write(PSX::COP0::CAUSE, 0xFFFF_FFFF)
    # Only bits 8-9 (software interrupts) should be set
    assert_equal 0x0300, @cop0.cause
  end

  def test_prid_read_only
    @cop0.write(PSX::COP0::PRID, 0x1234_5678)
    assert_equal 0x0000_0002, @cop0.read(PSX::COP0::PRID)
  end

  def test_epc_writable
    @cop0.write(PSX::COP0::EPC, 0x8000_1234)
    assert_equal 0x8000_1234, @cop0.epc
  end

  # Cache isolation tests
  def test_cache_isolated
    refute @cop0.cache_isolated?
    @cop0.sr = PSX::COP0::SR_ISC
    assert @cop0.cache_isolated?
  end

  # BEV (boot exception vector) tests
  def test_bev_flag
    refute @cop0.bev?
    @cop0.sr = PSX::COP0::SR_BEV
    assert @cop0.bev?
  end

  # Interrupt tests
  def test_interrupts_disabled_by_default
    refute @cop0.interrupts_enabled?
  end

  def test_interrupts_enabled
    @cop0.sr = PSX::COP0::SR_IEC
    assert @cop0.interrupts_enabled?
  end

  def test_interrupt_pending_when_masked_and_enabled
    # Enable interrupts and set interrupt mask for hardware IRQ
    @cop0.sr = PSX::COP0::SR_IEC | 0x0400  # Enable + mask bit 10 (hardware)
    refute @cop0.interrupt_pending?

    # Set hardware IRQ
    @cop0.set_hardware_irq(true)
    assert @cop0.interrupt_pending?

    # Clear hardware IRQ
    @cop0.set_hardware_irq(false)
    refute @cop0.interrupt_pending?
  end

  def test_no_interrupt_when_disabled
    @cop0.sr = 0x0400  # Mask bit set but IEC clear
    @cop0.set_hardware_irq(true)
    refute @cop0.interrupt_pending?
  end

  def test_no_interrupt_when_masked
    @cop0.sr = PSX::COP0::SR_IEC  # Enabled but no mask
    @cop0.set_hardware_irq(true)
    refute @cop0.interrupt_pending?
  end

  # Exception handling tests
  def test_enter_exception_sets_epc
    vector = @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000)
    assert_equal 0x8000_1000, @cop0.epc
  end

  def test_enter_exception_delay_slot_adjusts_epc
    @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1004, in_delay_slot: true)
    assert_equal 0x8000_1000, @cop0.epc  # PC - 4
  end

  def test_enter_exception_sets_cause_code
    @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000)
    # Exception code in bits 2-6
    assert_equal PSX::COP0::EXC_SYS << 2, @cop0.cause & 0x7C
  end

  def test_enter_exception_sets_bd_flag_in_delay_slot
    @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000, in_delay_slot: true)
    assert_equal 0x8000_0000, @cop0.cause & 0x8000_0000
  end

  def test_enter_exception_shifts_mode_bits
    @cop0.sr = PSX::COP0::SR_IEC | PSX::COP0::SR_KUC  # Set current bits
    @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000)
    # Current should shift to previous, current should be 0
    assert_equal 0, @cop0.sr & 0x03  # Current bits clear
    assert_equal 0x0C, @cop0.sr & 0x0C  # Previous bits set
  end

  def test_enter_exception_bev_vector
    @cop0.sr = PSX::COP0::SR_BEV
    vector = @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000)
    assert_equal 0xBFC0_0180, vector
  end

  def test_enter_exception_normal_vector
    @cop0.sr = 0  # BEV clear
    vector = @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000)
    assert_equal 0x8000_0080, vector
  end

  def test_enter_exception_sets_badvaddr
    @cop0.enter_exception(PSX::COP0::EXC_ADEL, 0x8000_1000, bad_addr: 0xDEAD_BEEF)
    assert_equal 0xDEAD_BEEF, @cop0.read(PSX::COP0::BADVADDR)
  end

  # RFE (return from exception) tests
  def test_return_from_exception_shifts_mode_back
    # Simulate being in exception handler
    @cop0.sr = 0x0C  # Previous bits set (were current before exception)
    @cop0.return_from_exception
    assert_equal 0x03, @cop0.sr & 0x03  # Current bits restored
  end

  def test_exception_and_return_roundtrip
    @cop0.sr = PSX::COP0::SR_IEC | PSX::COP0::SR_KUC
    original_mode = @cop0.sr & 0x3F

    @cop0.enter_exception(PSX::COP0::EXC_SYS, 0x8000_1000)
    @cop0.return_from_exception

    # Should restore original current bits
    assert_equal original_mode & 0x0F, @cop0.sr & 0x0F
  end
end
