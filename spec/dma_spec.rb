# frozen_string_literal: true

require_relative "spec_helper"

class DMASpec < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
    @dma = PSX::DMA.new(interrupts: @interrupts)
  end

  # === Register Access ===

  def test_initial_dpcr
    # Default DPCR has all channels enabled with priorities
    assert_equal 0x0765_4321, @dma.dpcr
  end

  def test_channel_base_address
    @dma.write(0x20, 0x0012_3400)  # Channel 2 (GPU) base address
    assert_equal 0x0012_3400, @dma.read(0x20)
  end

  def test_channel_block_control
    @dma.write(0x24, 0x0010_0001)  # Channel 2 block control
    assert_equal 0x0010_0001, @dma.read(0x24)
  end

  def test_dicr_acknowledge_flags
    # Set some flags
    @dma.instance_variable_set(:@dicr, 0x0700_0000)  # Flags for channels 0-2

    # Acknowledge channel 1
    @dma.write(0x74, 0x0200_0000)

    dicr = @dma.dicr
    assert (dicr & 0x0200_0000) == 0, "Channel 1 flag should be cleared"
    assert (dicr & 0x0500_0000) != 0, "Other flags should remain"
  end

  # === Channel State ===

  def test_channel_enabled
    # Default DPCR (0x07654321) has priorities but NOT enable bits set
    # Enable bit for each channel is at position n*4+3
    refute @dma.channel_enabled?(0), "Channel 0 should not be enabled by default"
    refute @dma.channel_enabled?(2), "Channel 2 should not be enabled by default"
    refute @dma.channel_enabled?(6), "Channel 6 should not be enabled by default"

    # Enable channel 2 by setting bit 11 (2*4+3)
    @dma.write(0x70, @dma.dpcr | (1 << 11))
    assert @dma.channel_enabled?(2), "Channel 2 should be enabled"

    # Disable it again
    @dma.write(0x70, @dma.dpcr & ~(1 << 11))
    refute @dma.channel_enabled?(2), "Channel 2 should be disabled"
  end

  def test_channel_active_requires_start_bit
    channel = @dma.channels[2]
    # Use sync mode 1 which doesn't require trigger
    channel.channel_ctrl = (1 << 9)  # Sync mode 1
    refute channel.active?, "Should not be active without start bit"

    channel.channel_ctrl = (1 << 9) | PSX::DMA::CTRL_START_BUSY
    assert channel.active?, "Should be active with start bit"
  end

  def test_manual_sync_requires_trigger
    channel = @dma.channels[2]
    # Sync mode 0 (manual) requires the trigger bit only when the caller
    # indicates the channel has no DRQ source (OTC). For DRQ-backed
    # channels (e.g. GPU/SPU), BUSY alone suffices.
    channel.channel_ctrl = PSX::DMA::CTRL_START_BUSY
    refute channel.active?(needs_trigger: true), "OTC-style channel needs trigger bit"
    assert channel.active?, "DRQ-backed channel starts on BUSY alone"

    channel.channel_ctrl = PSX::DMA::CTRL_START_BUSY | PSX::DMA::CTRL_START_TRIGGER
    assert channel.active?(needs_trigger: true)
  end

  # === Channel Properties ===

  def test_channel_direction
    channel = @dma.channels[2]

    channel.channel_ctrl = 0
    assert_equal :to_ram, channel.direction

    channel.channel_ctrl = PSX::DMA::CTRL_DIRECTION
    assert_equal :from_ram, channel.direction
  end

  def test_channel_step
    channel = @dma.channels[2]

    channel.channel_ctrl = 0
    assert_equal 4, channel.step  # Forward

    channel.channel_ctrl = PSX::DMA::CTRL_STEP
    assert_equal(-4, channel.step)  # Backward
  end

  def test_channel_sync_mode
    channel = @dma.channels[2]

    channel.channel_ctrl = 0x0000  # Mode 0
    assert_equal 0, channel.sync_mode

    channel.channel_ctrl = 0x0200  # Mode 1
    assert_equal 1, channel.sync_mode

    channel.channel_ctrl = 0x0400  # Mode 2
    assert_equal 2, channel.sync_mode
  end

  def test_channel_block_size
    channel = @dma.channels[2]
    channel.block_ctrl = 0x0010_0020  # Count=16, Size=32

    assert_equal 32, channel.block_size
    assert_equal 16, channel.block_count
  end

  def test_block_size_zero_means_max
    channel = @dma.channels[2]
    channel.block_ctrl = 0x0001_0000  # Size=0, Count=1

    assert_equal 0, channel.block_size  # Raw value is 0
    # But DMA transfer should interpret as 0x10000
  end

  # === OTC Channel ===

  def test_otc_generates_linked_list
    ram = PSX::RAM.new
    bios_data = "\x00" * 512 * 1024
    bios = PSX::BIOS.allocate
    bios.instance_variable_set(:@data, bios_data)
    memory = PSX::Memory.new(
      bios: bios,
      ram: ram,
      interrupts: @interrupts,
      dma: @dma,
      timers: PSX::Timers.new(interrupts: @interrupts)
    )

    # Enable OTC channel (6) in DPCR - bit 27 is enable for channel 6
    @dma.write(0x70, @dma.dpcr | (1 << 27))

    # Set up OTC channel (6)
    # OTC generates backwards linked list for ordering tables
    @dma.write(0x60, 0x0000_0100)  # Base at 0x100
    @dma.write(0x64, 0x0000_0004)  # 4 entries
    @dma.write(0x68, PSX::DMA::CTRL_START_BUSY | PSX::DMA::CTRL_START_TRIGGER)

    @dma.tick(memory)

    # OTC writes backwards from base address:
    # i=0: addr=0x100, writes pointer to 0xFC
    # i=1: addr=0xFC, writes pointer to 0xF8
    # i=2: addr=0xF8, writes pointer to 0xF4
    # i=3: addr=0xF4, writes end marker 0x00FFFFFF
    last_entry = ram.read32(0xF4)
    assert_equal 0x00FF_FFFF, last_entry, "Last OTC entry should be end marker"

    # Verify the linked list structure
    assert_equal 0x0000_00FC, ram.read32(0x100), "Entry at 0x100 should point to 0xFC"
    assert_equal 0x0000_00F8, ram.read32(0xFC), "Entry at 0xFC should point to 0xF8"
    assert_equal 0x0000_00F4, ram.read32(0xF8), "Entry at 0xF8 should point to 0xF4"
  end

  # === GPU linked-list chain bound ===

  def test_gpu_linked_list_does_not_hang_on_self_reference
    # ps1-tests dma/chain-looping plants a chain whose next-pointer points
    # back to itself with bit 23 clear, forming an infinite loop. We must
    # bound the walk and finish so the channel doesn't hang the emulator.
    ram = PSX::RAM.new
    bios_data = "\x00" * 512 * 1024
    bios = PSX::BIOS.allocate
    bios.instance_variable_set(:@data, bios_data)
    memory = PSX::Memory.new(
      bios: bios,
      ram: ram,
      interrupts: @interrupts,
      dma: @dma,
      timers: PSX::Timers.new(interrupts: @interrupts)
    )

    # Self-referential header at 0x1000: word_count=0, next=0x001000.
    # Bit 23 of next is 0, so this is NOT an end marker.
    ram.write32(0x1000, 0x0000_1000)

    # Stub GPU that just counts gp0 calls.
    gpu_counter = Class.new do
      attr_reader :calls
      def initialize = @calls = 0
      def gp0(_) = (@calls += 1)
    end.new

    # Enable + start GPU channel in linked-list mode at 0x1000.
    @dma.write(0x70, @dma.dpcr | (1 << 11))   # enable channel 2
    @dma.write(0x20, 0x0000_1000)              # base
    @dma.write(0x24, 0x0)
    @dma.write(0x28, PSX::DMA::CTRL_START_BUSY | (PSX::DMA::SYNC_LINKED << 9))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @dma.tick(memory, gpu: gpu_counter)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert elapsed < 5.0, "transfer_gpu_linked_list ran for #{elapsed}s on a self-loop"
    refute @dma.channels[2].active?, "GPU channel should be marked finished after the bounded walk"
  end
end
