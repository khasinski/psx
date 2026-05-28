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
end
