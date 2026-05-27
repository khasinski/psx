# frozen_string_literal: true

require_relative "spec_helper"

class SIO0Test < Minitest::Test
  CTRL_TXEN        = 1 << 0
  CTRL_JOYN_OUTPUT = 1 << 1
  CTRL_ACK         = 1 << 4
  CTRL_RESET       = 1 << 6
  CTRL_ACK_INT_EN  = 1 << 12
  CTRL_SLOT        = 1 << 13

  def setup
    @irqs = PSX::Interrupts.new
    @button_state = 0xFFFF
    @sio = PSX::SIO0.new(
      interrupts: @irqs,
      controller_state: -> { @button_state }
    )
    # Default: select slot 1, enable TX + ACK IRQ (what the BIOS does).
    select_slot_1
  end

  def select_slot_1
    @sio.write16(0x4A, CTRL_TXEN | CTRL_JOYN_OUTPUT | CTRL_ACK_INT_EN)
  end

  def tx(byte)
    @sio.write8(0x40, byte)
  end

  def rx
    @sio.read8(0x40)
  end

  def status
    @sio.read32(0x44)
  end

  # --- Protocol -----------------------------------------------------------

  def test_digital_pad_full_sequence
    tx(0x01); a = rx
    tx(0x42); b = rx
    tx(0x00); c = rx
    tx(0x00); d = rx
    tx(0x00); e = rx
    assert_equal 0xFF, a, "step 0 response is high-Z (0xFF)"
    assert_equal 0x41, b, "digital pad ID hi byte"
    assert_equal 0x5A, c, "ready byte"
    assert_equal 0xFF, d, "buttons low (no presses)"
    assert_equal 0xFF, e, "buttons high (no presses)"
  end

  def test_button_state_reaches_rx
    @button_state = 0xFFFF & ~(1 << 14)  # X pressed (active low)
    tx(0x01); rx
    tx(0x42); rx
    tx(0x00); rx
    tx(0x00); btn_lo = rx
    tx(0x00); btn_hi = rx
    assert_equal 0xFF, btn_lo
    # X is bit 14 -> hi byte bit 6
    assert_equal 0xFF & ~(1 << 6), btn_hi
  end

  def test_irq_fires_on_each_acked_byte
    @irqs.write_stat(0)  # clear any pending bits via write 0
    @irqs.write_mask(PSX::Interrupts::IRQ_CONTROLLER)
    tx(0x01)
    @sio.tick(1000)  # advance past the scheduled /ACK delay
    assert (@irqs.stat & PSX::Interrupts::IRQ_CONTROLLER) != 0,
           "IRQ_CONTROLLER should be raised once the /ACK delay elapses"
  end

  def test_last_byte_does_not_ack
    # ACK IRQ should fire for bytes 0..3 but not the 5th (last) byte.
    [0x01, 0x42, 0x00, 0x00].each do |b|
      tx(b); rx
      @sio.tick(1000)
      @sio.write16(0x4A, CTRL_TXEN | CTRL_JOYN_OUTPUT | CTRL_ACK | CTRL_ACK_INT_EN)
      @sio.write16(0x4A, CTRL_TXEN | CTRL_JOYN_OUTPUT | CTRL_ACK_INT_EN)
      @irqs.instance_variable_set(:@stat, 0)
    end
    tx(0x00); rx
    @sio.tick(1000)
    assert_equal 0, @irqs.stat & PSX::Interrupts::IRQ_CONTROLLER,
                 "no /ACK after the final protocol byte"
  end

  def test_memcard_get_id_sequence
    @irqs.instance_variable_set(:@stat, 0)
    tx(0x81)
    @sio.tick(1000)
    assert (@irqs.stat & PSX::Interrupts::IRQ_CONTROLLER) != 0,
           "memcard select byte should /ACK"
    assert_equal 0xFF, rx

    tx(0x53); flag = rx
    tx(0x00); id1 = rx
    tx(0x00); id2 = rx
    tx(0x00); ack1 = rx
    tx(0x00); ack2 = rx
    tx(0x00); b1 = rx
    tx(0x00); b2 = rx
    tx(0x00); b3 = rx
    tx(0x00); b4 = rx

    assert_equal 0x08, flag, "fresh formatted card reports no-write-yet flag"
    assert_equal [0x5A, 0x5D, 0x5C, 0x5D, 0x04, 0x00, 0x00, 0x80],
                 [id1, id2, ack1, ack2, b1, b2, b3, b4]
  end

  def test_memcard_read_formatted_header_frame
    read = memcard_read_frame(0)

    assert_equal "MC", read.byteslice(0, 2)
    assert_equal read.bytes[0...0x7F].reduce(0) { |acc, b| acc ^ b }, read.getbyte(0x7F)
  end

  def test_memcard_write_then_read_frame
    bytes = Array.new(128) { |i| i & 0xFF }
    memcard_write_frame(5, bytes)

    assert_equal bytes.pack("C*"), memcard_read_frame(5)
  end

  def test_slot2_does_not_respond
    @sio.write16(0x4A, CTRL_TXEN | CTRL_JOYN_OUTPUT | CTRL_ACK_INT_EN | CTRL_SLOT)
    @irqs.instance_variable_set(:@stat, 0)
    tx(0x01)
    @sio.tick(1000)
    assert_equal 0xFF, rx
    refute (@irqs.stat & PSX::Interrupts::IRQ_CONTROLLER) != 0,
           "slot 2 is empty -> no /ACK"
  end

  # --- Status / control --------------------------------------------------

  def test_status_tx_ready_always_set
    s = status
    assert (s & (1 << 0)) != 0, "TX Ready 1"
    assert (s & (1 << 2)) != 0, "TX Ready 2"
    assert_equal 0, s & (1 << 7), "/ACK should be high/unasserted by default"
  end

  def test_ack_input_bit_pulses_when_device_acknowledges
    tx(0x01)
    assert_equal 0, status & (1 << 7), "/ACK should not assert immediately"

    @sio.tick(500)
    assert (status & (1 << 7)) != 0, "/ACK bit should assert after the scheduled delay"

    @sio.tick(250)
    assert_equal 0, status & (1 << 7), "/ACK pulse should return high"
  end

  def test_status_rx_fifo_not_empty_after_tx
    tx(0x01)
    assert (status & (1 << 1)) != 0, "RX FIFO not empty"
    rx
    assert_equal 0, status & (1 << 1), "FIFO drained"
  end

  def test_ctrl_ack_bit_clears_irq
    tx(0x01)
    @sio.tick(1000)
    assert (@irqs.stat & PSX::Interrupts::IRQ_CONTROLLER) != 0
    @sio.write16(0x4A, CTRL_TXEN | CTRL_JOYN_OUTPUT | CTRL_ACK | CTRL_ACK_INT_EN)
    assert_equal 0, status & (1 << 9), "JOY_STAT IRQ flag cleared"
  end

  def test_reset_clears_protocol_state
    tx(0x01); rx
    tx(0x42); rx  # we're now mid-sequence
    @sio.write16(0x4A, CTRL_RESET)
    # Re-select and verify protocol restarts at step 0
    select_slot_1
    tx(0x01)
    assert_equal 0xFF, rx, "after reset the protocol begins at step 0"
  end

  private

  def reselect_slot_1
    @sio.write16(0x4A, CTRL_TXEN | CTRL_ACK_INT_EN)
    select_slot_1
  end

  def memcard_read_frame(frame)
    reselect_slot_1
    tx(0x81); rx
    tx(0x52); rx
    tx(0x00); rx # 5A
    tx(0x00); rx # 5D
    tx((frame >> 8) & 0xFF); rx
    tx(frame & 0xFF); rx
    tx(0x00); rx # 5C
    tx(0x00); rx # 5D
    tx(0x00); rx # address MSB echo
    tx(0x00); rx # address LSB echo
    data = 128.times.map do
      tx(0x00)
      rx
    end
    tx(0x00)
    checksum = rx
    tx(0x00)
    end_byte = rx

    expected_checksum = ((frame >> 8) & 0xFF) ^ (frame & 0xFF)
    data.each { |b| expected_checksum ^= b }
    assert_equal expected_checksum & 0xFF, checksum
    assert_equal 0x47, end_byte

    data.pack("C*")
  end

  def memcard_write_frame(frame, bytes)
    reselect_slot_1
    tx(0x81); rx
    tx(0x57); rx
    tx(0x00); rx # 5A
    tx(0x00); rx # 5D
    tx((frame >> 8) & 0xFF); rx
    tx(frame & 0xFF); rx
    bytes.each do |byte|
      tx(byte)
      rx
    end
    tx(bytes.reduce(((frame >> 8) & 0xFF) ^ (frame & 0xFF)) { |acc, b| acc ^ b })
    rx
    tx(0x00); rx # 5C
    tx(0x00); rx # 5D
    tx(0x00); end_byte = rx
    assert_equal 0x47, end_byte
  end
end
