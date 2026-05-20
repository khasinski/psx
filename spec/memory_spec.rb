# frozen_string_literal: true

require_relative "spec_helper"

class MemorySpec < Minitest::Test
  include TestHelpers

  def setup
    @env = create_cpu_with_ram
    @memory = @env[:memory]
    @ram = @env[:ram]
  end

  # === Instruction-fetch permission ===

  def test_fetchable_allows_ram
    assert @memory.fetchable?(0x0000_0000)
    assert @memory.fetchable?(0x0010_0000)
    assert @memory.fetchable?(0x801F_FFF0)  # KSEG0 RAM mirror
    assert @memory.fetchable?(0xA000_0000)  # KSEG1 RAM mirror
  end

  def test_fetchable_allows_bios
    assert @memory.fetchable?(0xBFC0_0000)  # KSEG1 BIOS
    assert @memory.fetchable?(0x9FC0_4000)  # KSEG0 BIOS
  end

  def test_fetchable_blocks_scratchpad
    refute @memory.fetchable?(0x1F80_0000)
    refute @memory.fetchable?(0x1F80_03FC)
  end

  def test_fetchable_blocks_irq_mdec_timer_sio
    refute @memory.fetchable?(0x1F80_1070)  # IRQ I_STAT
    refute @memory.fetchable?(0x1F80_1820)  # MDEC0 data
    refute @memory.fetchable?(0x1F80_1100)  # Timer 0
    refute @memory.fetchable?(0x1F80_1040)  # JOY/SIO
  end

  def test_fetchable_allows_dma_spu_gpu
    assert @memory.fetchable?(0x1F80_1080)  # DMA channel 0 base
    assert @memory.fetchable?(0x1F80_10F0)  # DPCR
    assert @memory.fetchable?(0x1F80_1810)  # GPU GP0 read
    assert @memory.fetchable?(0x1F80_1C00)  # SPU voice 0
    assert @memory.fetchable?(0x1F80_1FFC)  # SPU end
  end

  # === SPU register shadow (read-back) ===

  def test_spu_register_writes_round_trip_via_io_read32
    # Real hardware preserves SPU register writes; cpu/code-in-io's
    # testCodeInSPU writes a `jr ra` (0x03E0_0008) to voice 0 and reads
    # it back via instruction fetch. We need the same.
    @memory.spu = PSX::SPU.new
    @memory.write32(0x1F80_1C00, 0x03E0_0008)
    assert_equal 0x03E0_0008, @memory.read32(0x1F80_1C00)
  end

  # === Address Translation ===

  def test_kseg0_maps_to_physical
    # KSEG0: 0x80000000-0x9FFFFFFF -> Physical 0x00000000-0x1FFFFFFF
    @ram.write32(0x100, 0xDEADBEEF)

    result = @memory.read32(0x8000_0100)
    assert_equal 0xDEADBEEF, result
  end

  def test_kseg1_maps_to_physical
    # KSEG1: 0xA0000000-0xBFFFFFFF -> Physical 0x00000000-0x1FFFFFFF (uncached)
    @ram.write32(0x200, 0xCAFEBABE)

    result = @memory.read32(0xA000_0200)
    assert_equal 0xCAFEBABE, result
  end

  def test_kuseg_maps_to_physical
    # KUSEG: 0x00000000-0x7FFFFFFF -> Physical (with cache)
    @ram.write32(0x300, 0x12345678)

    result = @memory.read32(0x0000_0300)
    assert_equal 0x12345678, result
  end

  # === RAM Access ===

  def test_ram_write_and_read
    @memory.write32(0x8000_1000, 0xABCD_1234)
    result = @memory.read32(0x8000_1000)
    assert_equal 0xABCD_1234, result
  end

  def test_ram_mirrors
    # PS1 RAM is 2MB, mirrored 4 times in first 8MB
    @memory.write32(0x8000_0000, 0x11111111)

    # Should read same value from mirror
    result = @memory.read32(0x8020_0000)
    assert_equal 0x11111111, result
  end

  def test_byte_access
    @memory.write32(0x8000_0000, 0x04030201)

    assert_equal 0x01, @memory.read8(0x8000_0000)
    assert_equal 0x02, @memory.read8(0x8000_0001)
    assert_equal 0x03, @memory.read8(0x8000_0002)
    assert_equal 0x04, @memory.read8(0x8000_0003)
  end

  def test_halfword_access
    @memory.write32(0x8000_0000, 0x43214321)

    assert_equal 0x4321, @memory.read16(0x8000_0000)
    assert_equal 0x4321, @memory.read16(0x8000_0002)
  end

  # === BIOS Access ===

  def test_bios_is_readonly
    # Try to write to BIOS region
    original = @memory.read32(0xBFC0_0000)
    @memory.write32(0xBFC0_0000, 0xFFFFFFFF)
    after = @memory.read32(0xBFC0_0000)

    assert_equal original, after, "BIOS should be read-only"
  end

  # === Cache Isolation ===

  def test_cache_isolation_prevents_writes
    @memory.cache_isolated = true
    @memory.write32(0x8000_0000, 0xDEADBEEF)
    @memory.cache_isolated = false

    result = @memory.read32(0x8000_0000)
    refute_equal 0xDEADBEEF, result, "Write should be blocked when cache isolated"
  end
end

class RAMSpec < Minitest::Test
  def setup
    @ram = PSX::RAM.new
  end

  def test_ram_size
    # 2 MB of RAM as a 32-bit-word array.
    assert_equal (2 * 1024 * 1024) / 4, @ram.instance_variable_get(:@words).length
  end

  def test_ram_initialized_to_zero
    # Sample some locations
    assert_equal 0, @ram.read32(0)
    assert_equal 0, @ram.read32(0x100000)
  end

  def test_ram_write_read_32
    @ram.write32(0x1000, 0xDEADBEEF)
    assert_equal 0xDEADBEEF, @ram.read32(0x1000)
  end

  def test_ram_write_read_16
    @ram.write16(0x2000, 0xABCD)
    assert_equal 0xABCD, @ram.read16(0x2000)
  end

  def test_ram_write_read_8
    @ram.write8(0x3000, 0x42)
    assert_equal 0x42, @ram.read8(0x3000)
  end
end
