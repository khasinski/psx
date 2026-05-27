# frozen_string_literal: true

require_relative "spec_helper"

class SPUSpec < Minitest::Test
  def setup
    @interrupts = PSX::Interrupts.new
    @spu = PSX::SPU.new(interrupts: @interrupts)
  end

  def test_key_on_and_key_off_registers_read_back
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0003)
    @spu.write16(PSX::SPU::KEY_ON_HIGH, 0x0080)

    assert_equal 0x0003, @spu.read16(PSX::SPU::KEY_ON_LOW)
    assert_equal 0x0080, @spu.read16(PSX::SPU::KEY_ON_HIGH)

    @spu.write16(PSX::SPU::KEY_OFF_LOW, 0x0001)

    assert_equal 0x0001, @spu.read16(PSX::SPU::KEY_OFF_LOW)
    assert_equal 0x0080_0002, @spu.instance_variable_get(:@voice_active)
  end

  def test_key_on_clears_endx_for_started_voices
    @spu.instance_variable_set(:@endx, 0x00FF_FFFF)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0005)

    assert_equal 0xFFFA, @spu.read16(PSX::SPU::ENDX_LOW)
    assert_equal 0x00FF, @spu.read16(PSX::SPU::ENDX_HIGH)
  end

  def test_key_on_resets_voice_adsr_current_volume
    voice0_adsr_volume = 0xC00 + 0x0C
    @spu.write16(voice0_adsr_volume, 0x4321)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    assert_equal 0, @spu.read16(voice0_adsr_volume)
  end

  def test_state_snapshot_preserves_voice_key_state
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0040)
    snapshot = @spu.state_snapshot

    restored = PSX::SPU.new
    restored.restore_state(snapshot)

    assert_equal 0x0040, restored.read16(PSX::SPU::KEY_ON_LOW)
    assert_equal 0x0040, restored.instance_variable_get(:@voice_active)
  end

  def test_irq9_fires_when_transfer_address_matches_irq_address
    @interrupts.write_mask(PSX::Interrupts::IRQ_SPU)
    @spu.write16(PSX::SPU::SPU_IRQ_ADDR, 0x0100)
    @spu.write16(PSX::SPU::SPUCNT, 1 << 6)
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, 0x0100)

    assert_equal 1 << 6, @spu.read16(PSX::SPU::SPUSTAT) & (1 << 6)
    assert (@interrupts.stat & PSX::Interrupts::IRQ_SPU) != 0
  end

  def test_enabling_irq9_checks_current_transfer_address
    @interrupts.write_mask(PSX::Interrupts::IRQ_SPU)
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, 0x0100)
    @spu.write16(PSX::SPU::SPU_IRQ_ADDR, 0x0100)

    @spu.write16(PSX::SPU::SPUCNT, 1 << 6)
 
    assert_equal 1 << 6, @spu.read16(PSX::SPU::SPUSTAT) & (1 << 6)
    assert (@interrupts.stat & PSX::Interrupts::IRQ_SPU) != 0
  end

  def test_disabling_irq9_clears_spustat_irq_flag
    @spu.write16(PSX::SPU::SPU_IRQ_ADDR, 0x0100)
    @spu.write16(PSX::SPU::SPUCNT, 1 << 6)
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, 0x0100)

    @spu.write16(PSX::SPU::SPUCNT, 0)

    assert_equal 0, @spu.read16(PSX::SPU::SPUSTAT) & (1 << 6)
  end
end
