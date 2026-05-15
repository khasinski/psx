# frozen_string_literal: true

require_relative "spec_helper"

class CDROMSpec < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
    @cdrom = PSX::CDROM.new(interrupts: @interrupts)
  end

  # The BIOS' Init-wait poll on [0x800091C4] only ever sets the flag if its
  # CDROM-event callback runs, and that callback only runs if IRQ_CDROM
  # actually fires when our INT3/INT2 are delivered. IRQ_CDROM is gated by
  # `@irq_enable & @irq_flags`, so a `reset` that clears @irq_enable would
  # silently break every command issued after an Init — the BIOS would
  # poll forever and eventually halt at A(0xA1).
  def test_init_preserves_irq_enable
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)        # index = 0
    @cdrom.write8(1, 0x0A)     # Cmd Init

    drive_until_int(2)
    assert @interrupts.stat & PSX::Interrupts::IRQ_CDROM != 0,
           "IRQ_CDROM should be raised by Init's INT2 (was @irq_enable preserved?)"
    # The actual enable bits — should NOT be 0 after Init.
    assert_equal 0x1F, @cdrom.instance_variable_get(:@irq_enable)
  end

  # OpenBIOS's initiateDMA writes CDROM_REG3 = 0 then = 0x80 to gate the
  # data FIFO before kicking off DMA. If clearing BFRD wipes the sector
  # data, the subsequent DMA reads zeros and the BIOS' filesystem can't
  # parse PVD/SYSTEM.CNF/PSX.EXE. Real hardware preserves the buffer
  # across BFRD toggles; the bit just opens/closes the read port.
  def test_bfrd_toggle_preserves_data_buffer
    @cdrom.disc = build_one_sector_disc(("\xAA\xBB\xCC\xDD" + ("\x00" * 2044)).b)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)   # SetLoc LBA 0
    drain_response
    @cdrom.write8(1, 0x06)   # ReadN
    drain_response
    @cdrom.write8(1, 0x09)   # Pause -> deliver sector
    drive_until_int(1, max_ticks: 200)

    assert @cdrom.data_fifo_has_data?, "sector should be in FIFO before BFRD toggle"

    # Simulate BIOS' arm-DMA sequence: REG0=0, REG3=0, REG3=0x80.
    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x00)   # BFRD off
    @cdrom.write8(3, 0x80)   # BFRD on (rising edge resets read pointer)

    assert @cdrom.data_fifo_has_data?, "buffer must survive BFRD toggle"
    assert_equal 0xDDCCBBAA, @cdrom.dma_read_word, "first word must be the original sector data"
  end

  # ReadN + Pause back-to-back is the BIOS pattern for "read exactly one
  # sector". The Pause arrives well before the cycle-paced INT1 would have
  # delivered the sector, but the BIOS expects to still get one INT1 with
  # the sector data before Pause's INT2 lands.
  def test_pause_after_readn_delivers_pending_sector
    @cdrom.disc = build_one_sector_disc("PVD!"[0, 4].b + ("\x00" * 2044).b)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0)        # param: minute=0
    @cdrom.write8(2, 2)        # param: second=2
    @cdrom.write8(2, 0x00)     # param: frame=0 (BCD) — LBA 0
    @cdrom.write8(1, 0x02)     # Cmd SetLoc

    drain_response
    @cdrom.write8(1, 0x06)     # Cmd ReadN
    drain_response
    @cdrom.write8(1, 0x09)     # Cmd Pause — issued before the streaming INT1 fires
    int1_fired = drive_until_int(1, max_ticks: 200)
    assert int1_fired, "Pause should still let one INT1 land for the in-flight sector"
    assert @cdrom.data_fifo_has_data?, "Data FIFO should hold the sector after the INT1"
    # And the first word should be the magic we baked in.
    assert_equal 0x21445650, @cdrom.dma_read_word, "First word should be 'PVD!' (LE)"
  end

  private

  def build_one_sector_disc(user_data)
    raise "user_data must be 2048 bytes" if user_data.bytesize != 2048
    tmp = Tempfile.new(["disc", ".bin"])
    tmp.binmode
    sync = "\x00\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00".b
    msf  = [0x00, 0x02, 0x00].pack("C*")
    sub  = "\x00\x00\x08\x00\x00\x00\x08\x00".b
    ecc  = "\x00" * 280
    tmp.write(sync + msf + "\x02".b + sub + user_data + ecc)
    tmp.close
    PSX::Disc.from_bin(tmp.path)
  end

  def enable_irqs(mask)
    @cdrom.write8(0, 1)        # index = 1
    @cdrom.write8(2, mask)     # @irq_enable
    @cdrom.write8(0, 0)        # back to index 0
  end

  def drive_until_int(target_type, max_ticks: 100)
    max_ticks.times do
      @cdrom.tick(20_000)
      f = @cdrom.instance_variable_get(:@irq_flags)
      return true if f == target_type
    end
    false
  end

  def drain_response
    # Pretend the BIOS reads + acks. 1) read all response bytes, 2) ack
    # the IRQ flag bits.
    drive_until_int(3, max_ticks: 20)
    @cdrom.write8(0, 1)
    @cdrom.write8(3, 0x1F)     # ack all IRQ flag bits
    @cdrom.write8(0, 0)
  end
end

require "tempfile"
