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

  def test_data_fifo_reads_are_gated_by_bfrd
    @cdrom.disc = build_one_sector_disc(("\x11\x22\x33\x44" + ("\x00" * 2044)).b)
    deliver_first_sector

    assert @cdrom.data_fifo_has_data?, "sector buffer is present before BFRD is armed"
    assert_equal 0, @cdrom.read8(2), "data port should be closed while BFRD is clear"
    assert_equal 0, @cdrom.dma_read_word, "DMA should not drain the sector while BFRD is clear"

    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x80)

    assert_equal 0x11, @cdrom.read8(2), "BFRD opens the data port"
    assert_equal 0x44_33_22, @cdrom.dma_read_word & 0x00FF_FFFF
  end

  def test_status_drq_bit_follows_bfrd_request
    @cdrom.disc = build_one_sector_disc(("\xAA" * 2048).b)
    deliver_first_sector

    assert_equal 0, @cdrom.read8(0) & PSX::CDROM::STAT_DATA_FIFO_NOT_EMPTY,
                 "DRQ/status bit should stay clear until BFRD is set"

    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x80)
    assert_equal PSX::CDROM::STAT_DATA_FIFO_NOT_EMPTY,
                 @cdrom.read8(0) & PSX::CDROM::STAT_DATA_FIFO_NOT_EMPTY
  end

  def test_bfrd_clears_after_dma_consumes_sector_buffer
    @cdrom.disc = build_one_sector_disc(("\xAA" * 2048).b)
    deliver_first_sector

    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x80)
    assert @cdrom.dma_data_ready?

    512.times { @cdrom.dma_read_word }

    refute @cdrom.dma_data_ready?
    assert_equal 0, @cdrom.read8(0) & PSX::CDROM::STAT_DATA_FIFO_NOT_EMPTY,
                 "DuckStation clears BFRD/DRQ when DMA consumes the buffer"
  end

  def test_new_read_clears_open_sector_buffer
    @cdrom.disc = build_disc([
      ("OLD!" + "\x00" * 2044).b,
      ("NEW!" + "\x00" * 2044).b,
    ])
    deliver_first_sector

    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x80)
    assert @cdrom.dma_data_ready?, "first read leaves an open sector buffer"

    @cdrom.write8(2, 0)
    @cdrom.write8(2, 2)
    @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)   # SetLoc LBA 0, not the stream's next sector.
    drain_response
    @cdrom.write8(1, 0x06)   # ReadN starts a new read and clears buffers.
    drain_response

    refute @cdrom.data_fifo_has_data?
    refute @cdrom.dma_data_ready?
    assert_equal 0, @cdrom.read8(0) & PSX::CDROM::STAT_DATA_FIFO_NOT_EMPTY
  end

  def test_duplicate_readn_does_not_reset_active_stream
    @cdrom.disc = build_disc([
      ("ONE!" + "\x00" * 2044).b,
      ("TWO!" + "\x00" * 2044).b,
    ])
    deliver_first_sector
    next_sector_cycles = @cdrom.instance_variable_get(:@sector_cycles)
    sectors_since_read = @cdrom.instance_variable_get(:@sectors_since_read)

    @cdrom.write8(1, 0x06)   # Duplicate ReadN with no new SetLoc.
    drain_response

    assert_equal "ONE!".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
    assert_equal next_sector_cycles, @cdrom.instance_variable_get(:@sector_cycles)
    assert_equal sectors_since_read, @cdrom.instance_variable_get(:@sectors_since_read)
  end

  def test_new_read_cancels_pending_pause_second_response
    @cdrom.disc = build_disc([
      ("ONE!" + "\x00" * 2044).b,
      ("TWO!" + "\x00" * 2044).b,
    ])
    deliver_first_sector

    @cdrom.write8(1, 0x09)   # Pause queues a delayed INT2.
    drain_response

    @cdrom.write8(2, 0)
    @cdrom.write8(2, 2)
    @cdrom.write8(2, 1)
    @cdrom.write8(1, 0x02)   # SetLoc LBA 1.
    drain_response

    pending_pause = @cdrom.instance_variable_get(:@pending).find { |entry| entry[3] == 2 }
    refute_nil pending_pause
    pending_pause[0] = 1

    @cdrom.write8(1, 0x06)   # New ReadN clears old async/second response.
    drain_response

    @cdrom.tick(1)
    assert_equal 0, @cdrom.instance_variable_get(:@irq_flags),
                 "old Pause INT2 should not survive into the new read"
    assert drive_until_int(1, max_ticks: 20), "new read should deliver sector INT1"
    assert_equal "TWO!".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
  end

  def test_clearing_bfrd_resets_data_fifo_read_position
    @cdrom.disc = build_one_sector_disc(("\x01\x02\x03\x04" + ("\x00" * 2044)).b)
    deliver_first_sector

    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x80)
    assert_equal 0x01, @cdrom.read8(2)

    @cdrom.write8(3, 0x00)
    @cdrom.write8(3, 0x80)

    assert_equal 0x01, @cdrom.read8(2), "BFRD clear rewinds the current sector buffer"
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
    @cdrom.write8(0, 0)
    @cdrom.write8(3, 0x80)
    # And the first word should be the magic we baked in.
    assert_equal 0x21445650, @cdrom.dma_read_word, "First word should be 'PVD!' (LE)"
  end

  # Games may issue a new command while an older command's delayed second
  # response is still pending. The new short INT3 acknowledgement should not
  # be trapped behind that old long-delay response.
  def test_new_command_ack_can_overtake_delayed_second_response
    @cdrom.disc = build_one_sector_disc("PVD!"[0, 4].b + ("\x00" * 2044).b)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0)
    @cdrom.write8(2, 2)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x02)     # SetLoc
    drain_response

    @cdrom.write8(1, 0x06)     # ReadN
    drain_response
    @cdrom.write8(1, 0x09)     # Pause queues INT3 and a delayed INT2
    assert drive_until_int(1, max_ticks: 200), "Pause should deliver the in-flight INT1"
    ack_response
    assert drive_until_int(3, max_ticks: 20), "Pause INT3 should arrive"
    ack_response

    @cdrom.write8(1, 0x01)     # GetStat while Pause INT2 is still pending
    assert drive_until_int(3, max_ticks: 5),
           "new command INT3 should not wait for the older delayed INT2"
  end

  # whole_sector mode (SetMode bit 5) makes the data FIFO start at offset
  # 12 of the raw 2352-byte sector — header + sub-header + user data +
  # ECC — instead of the 2048-byte user-data slice. Rage Racer's CD-XA
  # streaming intro relied on this: it reads 12 bytes of header / sub-
  # header then 2048 bytes of user data per sector. Before this was
  # implemented we always served 2048 bytes regardless, so the "header"
  # DMA returned the first 12 bytes of user data and the user-data DMA
  # overshot our buffer by 12 bytes — @data_pos ended at 2060 in a 2048-
  # byte buffer and the game's wait-for-FIFO poll hung forever.
  def test_whole_sector_mode_returns_header_then_user_data
    # User data starts with a magic word so we can verify the header
    # offset is right.
    user_data = ("MARK" + "\x00" * 2044).b
    @cdrom.disc = build_one_sector_disc(user_data)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0xA0)   # SetMode params: bit 7 = 2x speed, bit 5 = whole_sector
    @cdrom.write8(1, 0x0E)   # Cmd SetMode
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)  # MSF 00:02:00
    @cdrom.write8(1, 0x02)   # Cmd SetLoc
    drain_response
    @cdrom.write8(1, 0x06)   # Cmd ReadN
    drain_response
    @cdrom.write8(1, 0x09)   # Cmd Pause (delivers the in-flight sector)
    drive_until_int(1, max_ticks: 200)

    buf = @cdrom.instance_variable_get(:@data_buffer)
    assert_equal 2340, buf.bytesize,
                 "whole_sector mode should serve 2340 bytes (header + sub-header + user + ECC)"

    # The MSF header is the first 4 bytes (3 MSF + 1 mode).
    assert_equal "\x00\x02\x00\x02".b, buf.byteslice(0, 4),
                 "first 4 bytes should be the MSF + mode header"
    # Sub-header (8 bytes) at offset 4 — what build_one_sector_disc baked in.
    assert_equal "\x00\x00\x08\x00\x00\x00\x08\x00".b, buf.byteslice(4, 8),
                 "next 8 bytes should be the CD-XA sub-header"
    # User data begins at offset 12.
    assert_equal "MARK".b, buf.byteslice(12, 4),
                 "user data should start at offset 12 in whole_sector mode"
  end

  def test_getloc_l_returns_last_delivered_sector_header_and_subheader
    user_data = ("LOC!" + "\x00" * 2044).b
    @cdrom.disc = build_one_sector_disc(user_data)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)   # SetLoc LBA 0
    drain_response
    @cdrom.write8(1, 0x06)   # ReadN
    drain_response
    @cdrom.write8(1, 0x09)   # Pause, delivering the in-flight sector
    drive_until_int(1, max_ticks: 200)
    ack_response
    drive_until_int(3, max_ticks: 20)
    ack_response
    drive_until_int(2, max_ticks: 100)
    ack_response

    @cdrom.write8(1, 0x10)   # GetlocL
    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }

    assert_equal [0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x08, 0x00], bytes
  end

  def test_getloc_p_returns_last_delivered_subq_not_next_read_lba
    @cdrom.disc = build_disc([
      ("ONE!" + "\x00" * 2044).b,
      ("TWO!" + "\x00" * 2044).b,
    ])

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)   # SetLoc LBA 0
    drain_response
    @cdrom.write8(1, 0x06)   # ReadN
    drain_response
    assert drive_until_int(1, max_ticks: 20)
    ack_response

    @cdrom.write8(1, 0x11)   # GetlocP
    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }

    assert_equal [0x01, 0x01, 0x00, 0x02, 0x00, 0x00, 0x02, 0x00], bytes
  end

  def test_getloc_p_returns_current_subq_before_first_read
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x11) # GetlocP

    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }
    assert_equal [0x01, 0x01, 0x00, 0x02, 0x00, 0x00, 0x02, 0x00], bytes
  end

  def test_seek_l_updates_getloc_l_from_target_sector
    @cdrom.disc = build_disc([
      ("ZERO" + "\x00" * 2044).b,
      ("ONE!" + "\x00" * 2044).b,
    ])

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(2, 0x01)
    @cdrom.write8(1, 0x02) # SetLoc LBA 1
    drain_response

    @cdrom.write8(1, 0x15) # SeekL
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response
    assert drive_until_int(2, max_ticks: 40)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x10) # GetlocL
    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }

    assert_equal [0x00, 0x02, 0x01, 0x02, 0x00, 0x00, 0x08, 0x00], bytes
  end

  def test_seek_l_accepts_implicit_track_one_pregap
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x30)
    @cdrom.write8(1, 0x02) # SetLoc LBA -120, inside the implicit track-one pregap
    drain_response

    @cdrom.write8(1, 0x15) # SeekL
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response
    assert drive_until_int(2, max_ticks: 40)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x10) # GetlocL
    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }

    assert_equal [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x08, 0x00], bytes
  end

  def test_init_preserves_last_valid_getloc_l_header
    @cdrom.disc = build_one_sector_disc("LOC!" + ("\x00" * 2044).b)

    deliver_first_sector
    @cdrom.write8(1, 0x0A) # Init
    drain_response
    assert drive_until_int(2, max_ticks: 40)
    ack_response

    @cdrom.write8(1, 0x10) # GetlocL
    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }

    assert_equal [0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x08, 0x00], bytes
  end

  def test_far_read_reports_seeking_until_first_sector_arrives
    @cdrom.disc = build_disc(Array.new(200) { "\x00".b * 2048 })

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x03)
    @cdrom.write8(2, 0x30)
    @cdrom.write8(1, 0x02) # SetLoc LBA 75
    drain_response

    @cdrom.write8(1, 0x06) # ReadN
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response

    @cdrom.tick(1_000_000)
    @cdrom.write8(1, 0x01) # GetStat
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response

    assert drive_until_int(1, max_ticks: 500)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_READING, @cdrom.read8(1)
  end

  def test_pause_during_far_read_keeps_seek_active_until_sector_arrives
    @cdrom.disc = build_disc(Array.new(200) { "\x00".b * 2048 })

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x03)
    @cdrom.write8(2, 0x30)
    @cdrom.write8(1, 0x02) # SetLoc LBA 105
    drain_response
    @cdrom.write8(1, 0x06) # ReadN
    drain_response

    @cdrom.write8(1, 0x09) # Pause before first sector is ready
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response

    @cdrom.tick(1_000_000)
    @cdrom.write8(1, 0x01) # GetStat
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response

    assert drive_until_int(1, max_ticks: 500)
    ack_response
    assert drive_until_int(2, max_ticks: 40)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
  end

  def test_seek_l_out_of_range_finishes_with_seek_error
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(2, 0x10)
    @cdrom.write8(1, 0x02) # SetLoc LBA 10, beyond the one-sector disc
    drain_response

    @cdrom.write8(1, 0x15) # SeekL
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response

    assert drive_until_int(5, max_ticks: 40)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEK_ERROR, @cdrom.read8(1)
    assert_equal 0x04, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x10) # GetlocL
    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEK_ERROR, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_NOT_READY, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x11) # GetlocP
    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEK_ERROR, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_NOT_READY, @cdrom.read8(1)
  end

  def test_readn_skips_audio_sectors_without_latching_seek_error
    @cdrom.disc = build_data_then_audio_disc

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x02) # SetLoc LBA 0
    drain_response

    @cdrom.write8(1, 0x06) # ReadN
    drain_response
    assert drive_until_int(1, max_ticks: 40)
    ack_response

    @cdrom.tick(PSX::CDROM::CYCLES_PER_SECTOR_1X * 2)

    refute @cdrom.instance_variable_get(:@stat) & PSX::CDROM::SF_SEEK_ERROR != 0,
           "audio sectors reached by a data read should not poison later command status"
    assert_operator @cdrom.instance_variable_get(:@read_lba), :>=, 2

    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0xA0)
    @cdrom.write8(1, 0x0E) # SetMode

    assert drive_until_int(3, max_ticks: 20)
    assert_equal 0, @cdrom.read8(1) & PSX::CDROM::SF_SEEK_ERROR
  end

  def test_seek_p_to_audio_track_completes_without_seek_error
    @cdrom.disc = build_data_then_audio_disc

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(2, 0x01)
    @cdrom.write8(1, 0x02) # SetLoc LBA 1, first audio sector
    drain_response

    @cdrom.write8(1, 0x16) # SeekP
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_SEEKING, @cdrom.read8(1)
    ack_response

    assert drive_until_int(2, max_ticks: 40)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x11) # GetlocP
    assert drive_until_int(3, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }
    assert_equal [0x02, 0x01, 0x00, 0x02, 0x00, 0x00, 0x02, 0x01], bytes
  end

  def test_invalid_command_returns_int5_command_error
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x00) # Sync/invalid on retail drives

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_COMMAND, @cdrom.read8(1)
  end

  def test_test_command_04_turns_motor_on
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x04)
    @cdrom.write8(1, 0x19) # Test

    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_NO_DISC | PSX::CDROM::SF_MOTOR_ON, @cdrom.read8(1)
  end

  def test_eject_disc_raises_shell_open_error_interrupt
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.eject_disc

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x01) # GetStat
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::SF_SHELL_OPEN, @cdrom.read8(1)
  end

  def test_insert_disc_reports_shell_closing_status_sequence
    @cdrom.insert_disc(build_one_sector_disc("\x00".b * 2048))
    enable_irqs(0x1F)

    [0x12, 0x10, 0x00].each do |expected|
      @cdrom.write8(0, 0)
      @cdrom.write8(1, 0x01) # GetStat
      assert drive_until_int(3, max_ticks: 20)
      assert_equal expected, @cdrom.read8(1)
      ack_response
    end
  end

  def test_test_command_05_returns_scex_counters_without_stat
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x05)
    @cdrom.write8(1, 0x19) # Test

    assert drive_until_int(3, max_ticks: 20)
    assert_equal [0x00, 0x00], 2.times.map { @cdrom.read8(1) }
  end

  def test_forward_errors_when_cdda_is_not_playing
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x04) # Forward

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_NOT_READY, @cdrom.read8(1)
  end

  def test_forward_and_backward_ack_while_cdda_is_playing
    @cdrom.disc = build_audio_disc(sectors: 4)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x03) # Play
    drain_response

    @cdrom.write8(1, 0x04) # Forward
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_PLAYING_CDDA, @cdrom.read8(1)
    ack_response

    @cdrom.write8(1, 0x05) # Backward
    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC | PSX::CDROM::SF_PLAYING_CDDA, @cdrom.read8(1)
  end

  def test_read_t_requires_one_session_parameter
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x12) # ReadT without session param

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_read_t_session_zero_errors
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x12) # ReadT session 0

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_ARGUMENT, @cdrom.read8(1)
  end

  def test_read_t_session_one_acknowledges_and_completes
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x01)
    @cdrom.write8(1, 0x12) # ReadT session 1

    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    ack_response

    assert drive_until_int(2, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
  end

  def test_get_q_requires_two_parameters_before_invalid_command_handling
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x1D) # GetQ without its two params

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_get_q_with_valid_arity_returns_invalid_command
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x1D) # GetQ

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_COMMAND, @cdrom.read8(1)
  end

  def test_videocd_requires_at_least_six_parameters
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    5.times { @cdrom.write8(2, 0x00) }
    @cdrom.write8(1, 0x1F) # VideoCD with too few params

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_videocd_with_valid_arity_returns_invalid_command
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    6.times { @cdrom.write8(2, 0x00) }
    @cdrom.write8(1, 0x1F) # VideoCD

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_COMMAND, @cdrom.read8(1)
  end

  def test_get_clock_rejects_stray_parameter_before_invalid_command_handling
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x18) # GetClock with stray param

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_get_clock_with_valid_arity_returns_invalid_command
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)

    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x18) # GetClock

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_COMMAND, @cdrom.read8(1)
  end

  def test_test_command_60_requires_two_address_bytes
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x60)
    @cdrom.write8(1, 0x19) # Test

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_test_command_60_reads_memory_as_zero
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x60)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x19) # Test

    assert drive_until_int(3, max_ticks: 20)
    assert_equal 0x00, @cdrom.read8(1)
  end

  def test_test_command_unknown_returns_invalid_command
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x99)
    @cdrom.write8(1, 0x19) # Test

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_COMMAND, @cdrom.read8(1)
  end

  def test_setloc_errors_for_missing_parameters
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(1, 0x02) # SetLoc with only 2 params

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_setloc_errors_for_out_of_range_bcd_fields
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(2, 0x60) # seconds must be below 0x60
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x02) # SetLoc

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_ARGUMENT, @cdrom.read8(1)
  end

  def test_setfilter_errors_for_wrong_parameter_count
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x12)
    @cdrom.write8(1, 0x0D) # Setfilter with only file param

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_setmode_errors_for_missing_parameter
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x0E) # Setmode with no params

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_get_td_errors_for_missing_parameter
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x14) # GetTD with no track param

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_getstat_errors_for_stray_parameter
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x00)
    @cdrom.write8(1, 0x01) # GetStat expects no params

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_play_errors_for_too_many_parameters
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x01)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(1, 0x03) # Play accepts at most one param

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_test_command_errors_without_subcommand
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x19) # Test requires one subcommand byte

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INCORRECT_NUMBER_OF_PARAMETERS, @cdrom.read8(1)
  end

  def test_get_tn_errors_when_drive_not_ready
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x13) # GetTN

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_NO_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_NOT_READY, @cdrom.read8(1)
  end

  def test_get_td_errors_for_invalid_bcd_track
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x1A)
    @cdrom.write8(1, 0x14) # GetTD

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_ARGUMENT, @cdrom.read8(1)
  end

  def test_get_td_errors_for_out_of_range_track
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x02)
    @cdrom.write8(1, 0x14) # GetTD

    assert drive_until_int(5, max_ticks: 20)
    assert_equal PSX::CDROM::SF_ERROR | PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    assert_equal PSX::CDROM::ERROR_REASON_INVALID_ARGUMENT, @cdrom.read8(1)
  end

  def test_get_id_returns_disc_region_string
    @cdrom.disc = disc_with_region(:pal)
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x1A) # GetID

    assert drive_until_int(3, max_ticks: 20)
    assert_equal PSX::CDROM::DEFAULT_STAT_DISC, @cdrom.read8(1)
    ack_response

    assert drive_until_int(2, max_ticks: 20)
    bytes = 8.times.map { @cdrom.read8(1) }
    assert_equal [0x02, 0x00, 0x20, 0x00] + "SCEE".bytes, bytes
  end

  def test_getparam_returns_mode_and_xa_filter
    @cdrom.disc = build_one_sector_disc("\x00".b * 2048)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0xA0)
    @cdrom.write8(1, 0x0E) # SetMode
    drain_response

    @cdrom.write8(2, 0x12)
    @cdrom.write8(2, 0x34)
    @cdrom.write8(1, 0x0D) # Setfilter
    drain_response

    @cdrom.write8(1, 0x0F) # Getparam
    assert drive_until_int(3, max_ticks: 20)
    bytes = 5.times.map { @cdrom.read8(1) }

    assert_equal [PSX::CDROM::DEFAULT_STAT_DISC, 0xA0, 0x00, 0x12, 0x34], bytes
  end

  # CD-XA streams are often software-filtered by file/channel. Rage Racer
  # reads a 44-byte XA/STR prefix for unwanted sectors and leaves the payload
  # unread; that must not stall the sector stream forever.
  def test_whole_sector_filter_prefix_read_does_not_block_next_sector
    first_payload = ("SKIP" + "\x00" * 2044).b
    second_payload = ("KEEP" + "\x00" * 2044).b
    @cdrom.disc = build_disc([first_payload, second_payload])

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0xA0)   # SetMode params: bit 7 = 2x speed, bit 5 = whole_sector
    @cdrom.write8(1, 0x0E)   # Cmd SetMode
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)   # Cmd SetLoc
    drain_response
    @cdrom.write8(1, 0x06)   # Cmd ReadN
    drain_response
    assert drive_until_int(1, max_ticks: 20), "first sector should arrive"

    44.times { @cdrom.read8(2) } # Consume only the filter prefix.
    ack_response

    assert drive_until_int(1, max_ticks: 20),
           "filter-prefix reads of unwanted XA sectors should not block the next INT1"
    assert_equal "KEEP".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(12, 4)
  end

  def test_unread_fifo_does_not_block_sector_irqs_while_bfrd_is_closed
    @cdrom.disc = build_disc([
      ("ONE!" + "\x00" * 2044).b,
      ("TWO!" + "\x00" * 2044).b,
    ])

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response

    assert drive_until_int(1, max_ticks: 20)
    assert_equal "ONE!".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
    ack_response

    assert drive_until_int(1, max_ticks: 40),
           "closed BFRD should allow timing-style tests to receive the next sector IRQ"
    assert_equal "TWO!".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
  end

  def test_xa_enabled_realtime_audio_sectors_are_not_delivered_to_data_fifo
    audio_payload = ("\x00" * 2048).b
    data_payload = ("DATA" + "\x00" * 2044).b
    audio_subheader = [0x12, 0x34, 0x44, 0x00] # realtime + audio
    data_subheader = [0x12, 0x34, 0x08, 0x00]  # data
    @cdrom.disc = build_disc([audio_payload, data_payload], subheaders: [audio_subheader, data_subheader])

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x40)   # SetMode params: bit 6 = XA enable
    @cdrom.write8(1, 0x0E)
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response

    assert drive_until_int(1, max_ticks: 40),
           "realtime XA audio sector should be consumed internally and the next data sector delivered"
    assert_equal "DATA".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
  end

  def test_decodes_simple_mono_xa_adpcm_sector_to_stereo_pcm
    whole = xa_adpcm_whole_sector(coding: 0x00, first_word: 0x0000_0001)
    @cdrom.instance_variable_set(:@last_sector_subheader, [0x12, 0x34, 0x44, 0x00])

    pcm = @cdrom.decode_xa_adpcm_sector(whole)
    samples = pcm.unpack("s<*")

    assert_equal 4032 * 2, samples.length
    assert_equal [4096, 4096], samples[0, 2]
  end

  def test_xa_audio_sector_is_decoded_to_sink_while_stream_continues_to_data_sector
    xa_payload = xa_adpcm_payload(first_word: 0x0000_0001)
    data_payload = ("DATA" + "\x00" * 2044).b
    audio_subheader = [0x12, 0x34, 0x44, 0x00] # realtime + audio, mono 4-bit
    data_subheader = [0x12, 0x34, 0x08, 0x00]
    @cdrom.disc = build_disc([xa_payload, data_payload], subheaders: [audio_subheader, data_subheader])
    decoded = []
    @cdrom.xa_adpcm_sink = ->(bytes) { decoded << bytes }

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x40)   # SetMode params: bit 6 = XA enable
    @cdrom.write8(1, 0x0E)
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response

    assert drive_until_int(1, max_ticks: 40)
    assert_equal 1, decoded.length
    assert_equal [4096, 4096], decoded.first.unpack("s<*")[0, 2]
    assert_equal "DATA".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
  end

  def test_mute_suppresses_xa_sink_but_still_decodes_stream
    xa_payload = xa_adpcm_payload(first_word: 0x0000_0001)
    data_payload = ("DATA" + "\x00" * 2044).b
    audio_subheader = [0x12, 0x34, 0x44, 0x00]
    data_subheader = [0x12, 0x34, 0x08, 0x00]
    @cdrom.disc = build_disc([xa_payload, data_payload], subheaders: [audio_subheader, data_subheader])
    decoded = []
    decode_calls = 0
    original_decode = @cdrom.method(:decode_xa_adpcm_sector)
    @cdrom.define_singleton_method(:decode_xa_adpcm_sector) do |whole|
      decode_calls += 1
      original_decode.call(whole)
    end
    @cdrom.xa_adpcm_sink = ->(bytes) { decoded << bytes }

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x0B)   # Cmd Mute
    drain_response
    @cdrom.write8(2, 0x40)   # SetMode params: bit 6 = XA enable
    @cdrom.write8(1, 0x0E)
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response

    assert drive_until_int(1, max_ticks: 40)
    assert_equal 1, decode_calls
    assert_empty decoded
    assert_equal "DATA".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
  end

  def test_demute_restores_xa_sink
    xa_payload = xa_adpcm_payload(first_word: 0x0000_0001)
    data_payload = ("DATA" + "\x00" * 2044).b
    audio_subheader = [0x12, 0x34, 0x44, 0x00]
    data_subheader = [0x12, 0x34, 0x08, 0x00]
    @cdrom.disc = build_disc([xa_payload, data_payload], subheaders: [audio_subheader, data_subheader])
    decoded = []
    @cdrom.xa_adpcm_sink = ->(bytes) { decoded << bytes }

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x0B)   # Cmd Mute
    drain_response
    @cdrom.write8(1, 0x0C)   # Cmd Demute
    drain_response
    @cdrom.write8(2, 0x40)   # SetMode params: bit 6 = XA enable
    @cdrom.write8(1, 0x0E)
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response

    assert drive_until_int(1, max_ticks: 40)
    assert_equal 1, decoded.length
    assert_equal [4096, 4096], decoded.first.unpack("s<*")[0, 2]
  end

  def test_mute_suppresses_cdda_sink_without_stopping_playback
    @cdrom.disc = build_audio_disc(sectors: 4)
    cdda = []
    @cdrom.cdda_sink = ->(bytes) { cdda << bytes }

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x0B)   # Cmd Mute
    drain_response
    @cdrom.write8(2, 0x01)   # track 1
    @cdrom.write8(1, 0x03)   # Cmd Play
    drain_response

    @cdrom.tick(PSX::CDROM::CYCLES_FIRST_SECTOR)
    assert_empty cdda
    assert_equal 1, @cdrom.instance_variable_get(:@cdda_lba)

    @cdrom.write8(0, 0)
    @cdrom.write8(1, 0x0C)   # Cmd Demute
    drain_response
    @cdrom.tick(PSX::CDROM::CYCLES_PER_SECTOR_1X)

    assert_equal 1, cdda.length
    assert_equal 2352, cdda.first.bytesize
  end

  def test_xa_filter_suppresses_mismatched_audio_sector_sink
    xa_payload = xa_adpcm_payload(first_word: 0x0000_0001)
    data_payload = ("DATA" + "\x00" * 2044).b
    audio_subheader = [0x12, 0x34, 0x44, 0x00]
    data_subheader = [0x12, 0x34, 0x08, 0x00]
    @cdrom.disc = build_disc([xa_payload, data_payload], subheaders: [audio_subheader, data_subheader])
    decoded = []
    @cdrom.xa_adpcm_sink = ->(bytes) { decoded << bytes }

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0x48)   # XA enable + XA filter
    @cdrom.write8(1, 0x0E)
    drain_response
    @cdrom.write8(2, 0x99)
    @cdrom.write8(2, 0x88)
    @cdrom.write8(1, 0x0D)
    drain_response

    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response

    assert drive_until_int(1, max_ticks: 40)
    assert_empty decoded
    assert_equal "DATA".b, @cdrom.instance_variable_get(:@data_buffer).byteslice(0, 4)
  end

  # Default (no whole_sector) still returns just the 2048-byte user-data
  # slice. Critical for the BIOS shell path that doesn't touch SetMode.
  def test_default_mode_serves_user_data_only
    user_data = ("DATA" + "\x00" * 2044).b
    @cdrom.disc = build_one_sector_disc(user_data)

    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response
    @cdrom.write8(1, 0x09)
    drive_until_int(1, max_ticks: 200)

    buf = @cdrom.instance_variable_get(:@data_buffer)
    assert_equal 2048, buf.bytesize
    assert_equal "DATA".b, buf.byteslice(0, 4),
                 "default mode should serve user data starting at offset 0"
  end

  private

  def build_one_sector_disc(user_data)
    build_disc([user_data])
  end

  def build_disc(payloads, subheaders: nil)
    payloads.each do |user_data|
      raise "user_data must be 2048 bytes" if user_data.bytesize != 2048
    end

    tmp = Tempfile.new(["disc", ".bin"])
    tmp.binmode
    sync = "\x00\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00".b
    ecc  = "\x00" * 280
    payloads.each_with_index do |user_data, lba|
      m, s, f = PSX::Disc.lba_to_msf(lba)
      msf = [PSX::Disc.to_bcd(m), PSX::Disc.to_bcd(s), PSX::Disc.to_bcd(f)].pack("C*")
      sub = subheaders&.fetch(lba, nil) || [0x00, 0x00, 0x08, 0x00]
      sub = (sub + sub).pack("C*")
      tmp.write(sync + msf + "\x02".b + sub + user_data + ecc)
    end
    tmp.close
    PSX::Disc.from_bin(tmp.path)
  end

  def build_audio_disc(sectors:)
    track = Struct.new(:number, :lba_start, :lba_length, keyword_init: true) do
      def audio? = true
      def data? = false
      def lba_end = lba_start + lba_length
    end.new(number: 1, lba_start: 0, lba_length: sectors)

    Object.new.tap do |disc|
      disc.define_singleton_method(:tracks) { [track] }
      disc.define_singleton_method(:track_count) { 1 }
      disc.define_singleton_method(:total_sectors) { sectors }
      disc.define_singleton_method(:track_for_lba) { |lba| lba >= 0 && lba < sectors ? track : nil }
      disc.define_singleton_method(:read_audio_sector) do |lba|
        lba >= 0 && lba < sectors ? ([lba & 0xFF].pack("C") + ("\x00" * 2351)).b : nil
      end
    end
  end

  def build_data_then_audio_disc
    data_track = Struct.new(:number, :lba_start, :lba_length, keyword_init: true) do
      def audio? = false
      def data? = true
      def lba_end = lba_start + lba_length
    end.new(number: 1, lba_start: 0, lba_length: 1)

    audio_track = Struct.new(:number, :lba_start, :lba_length, keyword_init: true) do
      def audio? = true
      def data? = false
      def lba_end = lba_start + lba_length
    end.new(number: 2, lba_start: 1, lba_length: 3)

    data_sector = begin
      sync = "\x00\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00".b
      msf = [0x00, 0x02, 0x00].pack("C*")
      sub = [0x00, 0x00, 0x08, 0x00].pack("C*") * 2
      sync + msf + "\x02".b + sub + ("DATA" + "\x00" * 2044).b + ("\x00" * 280).b
    end

    Object.new.tap do |disc|
      disc.define_singleton_method(:tracks) { [data_track, audio_track] }
      disc.define_singleton_method(:track_count) { 2 }
      disc.define_singleton_method(:total_sectors) { 4 }
      disc.define_singleton_method(:track_for_lba) do |lba|
        [data_track, audio_track].find { |track| lba >= track.lba_start && lba < track.lba_end }
      end
      disc.define_singleton_method(:pregap_lba?) { |_lba| false }
      disc.define_singleton_method(:read_whole_sector) { |lba| lba.zero? ? data_sector.byteslice(12, 2340) : raise("audio") }
      disc.define_singleton_method(:read_sector) { |lba| lba.zero? ? data_sector : raise("audio") }
      disc.define_singleton_method(:read_audio_sector) do |lba|
        lba >= 1 && lba < 4 ? ("\x00" * 2352).b : nil
      end
    end
  end

  def disc_with_region(region)
    Object.new.tap do |disc|
      disc.define_singleton_method(:region_code) { region }
    end
  end

  def xa_adpcm_whole_sector(coding:, first_word:)
    header = "\x00\x02\x00\x02".b
    sub = [0x12, 0x34, 0x44, coding].pack("C*") * 2
    header + sub + xa_adpcm_payload(first_word: first_word) + ("\x00" * 280).b
  end

  def xa_adpcm_payload(first_word:)
    chunks = ("\x00" * (18 * 128)).b
    chunks.setbyte(16, first_word & 0xFF)
    chunks.setbyte(17, (first_word >> 8) & 0xFF)
    chunks.setbyte(18, (first_word >> 16) & 0xFF)
    chunks.setbyte(19, (first_word >> 24) & 0xFF)
    chunks.byteslice(0, 2048)
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
    ack_response
  end

  def ack_response
    @cdrom.write8(0, 1)
    @cdrom.write8(3, 0x1F)     # ack all IRQ flag bits
    @cdrom.write8(0, 0)
  end

  def deliver_first_sector
    enable_irqs(0x1F)
    @cdrom.write8(0, 0)
    @cdrom.write8(2, 0); @cdrom.write8(2, 2); @cdrom.write8(2, 0)
    @cdrom.write8(1, 0x02)
    drain_response
    @cdrom.write8(1, 0x06)
    drain_response
    assert drive_until_int(1, max_ticks: 20)
    ack_response
  end
end

require "tempfile"
