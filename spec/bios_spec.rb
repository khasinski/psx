# frozen_string_literal: true

require_relative "spec_helper"
require "tempfile"

class BIOSTest < Minitest::Test
  def create_temp_bios(content)
    file = Tempfile.new(["bios", ".bin"])
    file.binmode
    file.write(content)
    file.close
    file
  end

  def test_loads_valid_bios
    content = "\x12\x34\x56\x78" + ("\x00" * (PSX::BIOS::SIZE - 4))
    file = create_temp_bios(content)

    bios = PSX::BIOS.new(file.path)
    assert_equal 0x12, bios.read8(0)
    assert_equal 0x34, bios.read8(1)
  ensure
    file&.unlink
  end

  def test_rejects_wrong_size
    content = "\x00" * 1024  # Too small
    file = create_temp_bios(content)

    assert_raises(ArgumentError) do
      PSX::BIOS.new(file.path)
    end
  ensure
    file&.unlink
  end

  def test_read8
    content = "\xAB\xCD\xEF\x12" + ("\x00" * (PSX::BIOS::SIZE - 4))
    file = create_temp_bios(content)

    bios = PSX::BIOS.new(file.path)
    assert_equal 0xAB, bios.read8(0)
    assert_equal 0xCD, bios.read8(1)
    assert_equal 0xEF, bios.read8(2)
    assert_equal 0x12, bios.read8(3)
  ensure
    file&.unlink
  end

  def test_read16_little_endian
    content = "\x34\x12\x78\x56" + ("\x00" * (PSX::BIOS::SIZE - 4))
    file = create_temp_bios(content)

    bios = PSX::BIOS.new(file.path)
    assert_equal 0x1234, bios.read16(0)
    assert_equal 0x5678, bios.read16(2)
  ensure
    file&.unlink
  end

  def test_read32_little_endian
    content = "\x78\x56\x34\x12\xEF\xCD\xAB\x90" + ("\x00" * (PSX::BIOS::SIZE - 8))
    file = create_temp_bios(content)

    bios = PSX::BIOS.new(file.path)
    assert_equal 0x12345678, bios.read32(0)
    assert_equal 0x90ABCDEF, bios.read32(4)
  ensure
    file&.unlink
  end

  def test_read_at_various_offsets
    content = ("\x00" * 0x100) + "\xDE\xAD\xBE\xEF" + ("\x00" * (PSX::BIOS::SIZE - 0x104))
    file = create_temp_bios(content)

    bios = PSX::BIOS.new(file.path)
    assert_equal 0xEFBEADDE, bios.read32(0x100)
  ensure
    file&.unlink
  end

  def test_file_not_found
    assert_raises(Errno::ENOENT) do
      PSX::BIOS.new("/nonexistent/path/bios.bin")
    end
  end
end
