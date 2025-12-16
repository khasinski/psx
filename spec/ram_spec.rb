# frozen_string_literal: true

require_relative "spec_helper"

class RAMTest < Minitest::Test
  def setup
    @ram = PSX::RAM.new
  end

  # Size constant test
  def test_size_is_2mb
    assert_equal 2 * 1024 * 1024, PSX::RAM::SIZE
  end

  # Initial state tests
  def test_initial_memory_is_zero
    assert_equal 0, @ram.read8(0)
    assert_equal 0, @ram.read16(0)
    assert_equal 0, @ram.read32(0)
    assert_equal 0, @ram.read32(0x100000)  # Middle of RAM
  end

  # 8-bit read/write tests
  def test_write8_read8
    @ram.write8(0, 0xAB)
    assert_equal 0xAB, @ram.read8(0)
  end

  def test_write8_masks_value
    @ram.write8(0, 0x1FF)  # More than 8 bits
    assert_equal 0xFF, @ram.read8(0)
  end

  def test_write8_at_various_offsets
    @ram.write8(0x1000, 0x12)
    @ram.write8(0x2000, 0x34)
    @ram.write8(0x100000, 0x56)

    assert_equal 0x12, @ram.read8(0x1000)
    assert_equal 0x34, @ram.read8(0x2000)
    assert_equal 0x56, @ram.read8(0x100000)
  end

  # 16-bit read/write tests
  def test_write16_read16
    @ram.write16(0, 0x1234)
    assert_equal 0x1234, @ram.read16(0)
  end

  def test_write16_little_endian
    @ram.write16(0, 0x1234)
    assert_equal 0x34, @ram.read8(0)  # Low byte first
    assert_equal 0x12, @ram.read8(1)  # High byte second
  end

  def test_read16_combines_bytes
    @ram.write8(0, 0x78)
    @ram.write8(1, 0x56)
    assert_equal 0x5678, @ram.read16(0)
  end

  # 32-bit read/write tests
  def test_write32_read32
    @ram.write32(0, 0x12345678)
    assert_equal 0x12345678, @ram.read32(0)
  end

  def test_write32_little_endian
    @ram.write32(0, 0x12345678)
    assert_equal 0x78, @ram.read8(0)
    assert_equal 0x56, @ram.read8(1)
    assert_equal 0x34, @ram.read8(2)
    assert_equal 0x12, @ram.read8(3)
  end

  def test_read32_combines_bytes
    @ram.write8(0, 0xEF)
    @ram.write8(1, 0xBE)
    @ram.write8(2, 0xAD)
    @ram.write8(3, 0xDE)
    assert_equal 0xDEADBEEF, @ram.read32(0)
  end

  # Address masking tests (RAM mirrors)
  def test_address_wraps_at_2mb
    @ram.write32(0, 0x12345678)
    # Reading at 2MB offset should wrap to 0
    assert_equal 0x12345678, @ram.read32(PSX::RAM::SIZE)
    assert_equal 0x12345678, @ram.read32(PSX::RAM::SIZE * 2)
  end

  def test_write_wraps_at_2mb
    @ram.write32(PSX::RAM::SIZE + 0x100, 0xDEADBEEF)
    assert_equal 0xDEADBEEF, @ram.read32(0x100)
  end

  def test_high_bits_masked
    @ram.write32(0xFF00_0100, 0xCAFEBABE)
    # Should write to 0x100 (masked)
    assert_equal 0xCAFEBABE, @ram.read32(0x100)
  end

  # Overwrite tests
  def test_overwrite_value
    @ram.write32(0, 0x11111111)
    @ram.write32(0, 0x22222222)
    assert_equal 0x22222222, @ram.read32(0)
  end

  def test_partial_overwrite
    @ram.write32(0, 0xFFFFFFFF)
    @ram.write16(0, 0x0000)
    assert_equal 0xFFFF0000, @ram.read32(0)
  end

  # Edge case tests
  def test_last_byte
    last_offset = PSX::RAM::SIZE - 1
    @ram.write8(last_offset, 0x42)
    assert_equal 0x42, @ram.read8(last_offset)
  end

  def test_boundary_write32
    # Write near end of RAM
    @ram.write32(PSX::RAM::SIZE - 4, 0xDEADBEEF)
    assert_equal 0xDEADBEEF, @ram.read32(PSX::RAM::SIZE - 4)
  end
end
