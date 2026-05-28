# frozen_string_literal: true

require_relative "spec_helper"

class MDECSpec < Minitest::Test
  def setup
    @mdec = PSX::MDEC.new
  end

  def test_empty_output_read_returns_open_bus_value
    assert_equal 0xFFFF_FFFF, @mdec.read32_data
  end

  def test_dma_in_request_follows_dma_in_enable_even_when_idle
    refute (@mdec.read32_status & PSX::MDEC::STAT_DATA_IN_REQ) != 0

    @mdec.write32_control(PSX::MDEC::CTRL_ENABLE_DMA_IN)

    assert (@mdec.read32_status & PSX::MDEC::STAT_DATA_IN_REQ) != 0
  end

  def test_control_reset_write_still_applies_dma_enable_bits
    @mdec.write32_control(PSX::MDEC::CTRL_RESET | PSX::MDEC::CTRL_ENABLE_DMA_IN)

    assert (@mdec.read32_status & PSX::MDEC::STAT_DATA_IN_REQ) != 0
  end

  def test_status_reports_duckstation_current_block_encoding
    assert_equal 4, (@mdec.read32_status >> 16) & 0x7
  end

  def test_starting_command_clears_pending_output_fifo
    load_flat_identity_tables

    @mdec.write32_data((PSX::MDEC::CMD_DECODE << 29) | (1 << 27) | 2)
    @mdec.write32_data(0xFE00_0000)
    @mdec.write32_data(0x0000_FE00)
    assert @mdec.data_out_available?

    @mdec.write32_data(PSX::MDEC::CMD_SET_QUANT_TABLE << 29)

    refute @mdec.data_out_available?
    assert (@mdec.read32_status & PSX::MDEC::STAT_OUTPUT_FIFO_EMPTY) != 0
  end

  def test_unknown_command_consumes_declared_parameter_words
    @mdec.write32_data((7 << 29) | 2)

    status = @mdec.read32_status
    assert (status & PSX::MDEC::STAT_COMMAND_BUSY) != 0
    assert_equal 1, status & 0xFFFF

    @mdec.write32_data(0x1111_2222)
    assert_equal 0, @mdec.read32_status & 0xFFFF

    @mdec.write32_data(0x3333_4444)
    status = @mdec.read32_status
    assert_equal 0, status & PSX::MDEC::STAT_COMMAND_BUSY
    assert_equal 0xFFFF, status & 0xFFFF
  end

  def test_idct_scale_table_is_transposed_on_load
    @mdec.write32_data(PSX::MDEC::CMD_SET_IDCT_TABLE << 29)
    32.times do |i|
      lo = i * 2
      hi = lo + 1
      @mdec.write32_data((hi << 16) | lo)
    end

    expected = Array.new(64) do |idx|
      x = idx % 8
      y = idx / 8
      x * 8 + y
    end
    assert_equal expected, @mdec.instance_variable_get(:@idct_table)
  end

  def test_rle_run_to_last_coefficient_terminates_block
    @mdec.instance_variable_set(:@idct_table, Array.new(64, 0))

    _block, pos = @mdec.send(:decode_block, [0x0000, 0xF800, 0x0123], 0, Array.new(64, 1))

    assert_equal 2, pos, "run reaching coefficient 63 should end the block without consuming next header"
  end

  def test_state_snapshot_preserves_pending_output_count
    load_flat_identity_tables

    @mdec.write32_data((PSX::MDEC::CMD_DECODE << 29) | (1 << 27) | 2)
    @mdec.write32_data(0xFE00_0000)
    @mdec.write32_data(0x0000_FE00)
    @mdec.read32_data

    restored = PSX::MDEC.new
    restored.restore_state(@mdec.state_snapshot)

    assert_equal @mdec.read32_data, restored.read32_data
    assert_equal @mdec.data_out_available?, restored.data_out_available?
  end

  def test_signed_24bit_colour_output_omits_unsigned_bias
    load_flat_identity_tables

    decode_flat_colour_macroblock(signed: false)
    unsigned_word = @mdec.read32_data

    load_flat_identity_tables
    decode_flat_colour_macroblock(signed: true)
    signed_word = @mdec.read32_data

    assert_equal 0x80_80_80_80, unsigned_word
    assert_equal 0x00_00_00_00, signed_word
  end

  def test_24bit_colour_output_packs_rgb_byte_order
    blocks = [
      Array.new(64, 32),  # Cr: raises red
      Array.new(64, 0),   # Cb
      Array.new(64, 0),
      Array.new(64, 0),
      Array.new(64, 0),
      Array.new(64, 0)
    ]
    output_bytes = []

    @mdec.send(:pack_24bit_into, output_bytes, blocks)

    assert output_bytes[0] > output_bytes[2], "first byte should be red, not blue"
    assert_equal [173, 105, 128], output_bytes[0, 3]
  end

  def test_15bit_colour_output_rounds_8bit_channels_to_5bit
    assert_equal 0x4631, @mdec.send(:rgb888_to_rgb555, 132, 132, 132)
  end

  def test_ps1tests_frame_15bit_samples_match_reference
    decoded = decode_mdec_frame_fixture(depth: 3)
    vram = swizzled_15bit_frame_vram(decoded)

    {
      [0, 0] => [88, 96, 96],
      [7, 7] => [80, 80, 88],
      [80, 80] => [176, 184, 168],
      [160, 120] => [224, 136, 24],
      [319, 239] => [24, 16, 16]
    }.each do |(x, y), expected_rgb|
      assert_rgb_close expected_rgb, rgb555_to_rgb888(vram[y * 1024 + x]), "pixel #{x},#{y}"
    end
  end

  private

  def load_flat_identity_tables
    @mdec.write32_data(PSX::MDEC::CMD_SET_QUANT_TABLE << 29)
    16.times { @mdec.write32_data(0x0101_0101) }

    @mdec.write32_data(PSX::MDEC::CMD_SET_IDCT_TABLE << 29)
    32.times { @mdec.write32_data(0x2000_2000) }
  end

  def decode_flat_colour_macroblock(signed:)
    command = (PSX::MDEC::CMD_DECODE << 29) | (2 << 27) | 6
    command |= 1 << 26 if signed
    @mdec.write32_data(command)
    6.times { @mdec.write32_data(0xFE00_0000) }
  end

  def decode_mdec_frame_fixture(depth:)
    load_ps1tests_mdec_tables

    words = File.binread(File.expand_path("../.tests/mdec/frame/sunset.mdec", __dir__)).unpack("V*")
    @mdec.write32_data((PSX::MDEC::CMD_DECODE << 29) | (depth << 27) | words.length)
    words.each { |word| @mdec.write32_data(word) }

    output = +""
    output << [@mdec.read32_data].pack("V") while @mdec.data_out_available?
    output
  end

  def load_ps1tests_mdec_tables
    source = File.read(File.expand_path("../.tests/common/mdec.cpp", __dir__))
    idct = source[/int16_t idct\[64\] = \{(.*?)\};/m, 1].scan(/-?\d+/).map(&:to_i)
    quant = source[/uint8_t quant\[128\] = \{(.*?)\};/m, 1].scan(/0x[0-9a-f]+|\d+/i).map { |n| Integer(n) }

    @mdec.write32_data((PSX::MDEC::CMD_SET_QUANT_TABLE << 29) | 1)
    quant.each_slice(4) do |slice|
      @mdec.write32_data(slice[0] | (slice[1] << 8) | (slice[2] << 16) | (slice[3] << 24))
    end

    @mdec.write32_data(PSX::MDEC::CMD_SET_IDCT_TABLE << 29)
    idct.each_slice(2) do |slice|
      @mdec.write32_data((slice[0] & 0xFFFF) | ((slice[1] & 0xFFFF) << 16))
    end
  end

  def swizzled_15bit_frame_vram(decoded)
    vram = Array.new(1024 * 512, 0)
    offset = 0

    20.times do |stripe|
      15.times do |macroblock_y|
        words = Array.new(256) do
          pixel = decoded.getbyte(offset).to_i | (decoded.getbyte(offset + 1).to_i << 8)
          offset += 2
          pixel
        end

        2.times do |pair_y|
          8.times do |y|
            2.times do |pair_x|
              block = pair_y * 2 + pair_x
              8.times do |x|
                dst_x = stripe * 16 + pair_x * 8 + x
                dst_y = macroblock_y * 16 + pair_y * 8 + y
                vram[dst_y * 1024 + dst_x] = words[block * 64 + y * 8 + x]
              end
            end
          end
        end
      end
    end

    vram
  end

  def rgb555_to_rgb888(pixel)
    [(pixel & 0x001F) << 3, (pixel & 0x03E0) >> 2, (pixel & 0x7C00) >> 7]
  end

  def assert_rgb_close(expected, actual, message)
    expected.zip(actual).each do |exp, act|
      assert_in_delta exp, act, 8, message
    end
  end
end
