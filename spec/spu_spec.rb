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
    assert_equal 0x0080_0003, @spu.instance_variable_get(:@voice_active)
    assert_equal :release, @spu.instance_variable_get(:@voices)[0].adsr_phase
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

  def test_decodes_simple_adpcm_block_from_spu_ram
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, 0)
    @spu.dma_write_word(0x00F1_0000) # shift/filter=0, flags=0, samples +1 and -1
    3.times { @spu.dma_write_word(0) }

    block = @spu.read_adpcm_block(0)
    samples, last = @spu.decode_adpcm_block(block)

    assert_equal 4096, samples[0]
    assert_equal(-4096, samples[1])
    assert_equal 28, samples.length
    assert_equal [0, 0], last
  end

  def test_transfer_data_register_reads_as_ff_ff
    @spu.write16(PSX::SPU::SPU_FIFO, 0x1234)

    assert_equal 0xFFFF, @spu.read16(PSX::SPU::SPU_FIFO)
  end

  def test_reserved_adpcm_shift_values_decode_as_shift_9
    block = {
      shift_filter: 0x0D,
      flags: 0,
      data: [0x01] + Array.new(13, 0),
    }

    samples, = @spu.decode_adpcm_block(block)

    assert_equal 8, samples[0]
  end

  def test_key_on_latches_start_address_and_decodes_first_block
    @spu.write16(0xC00 + 0x06, 0x0020) # voice 0 ADPCM start address
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, 0x0020)
    @spu.dma_write_word(0x00F1_0000)
    3.times { @spu.dma_write_word(0) }

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0x0020, voice.current_address
    assert_equal 4096, voice.decoded_samples[0]
    assert_equal(-4096, voice.decoded_samples[1])
  end

  def test_voice_tick_sets_endx_and_stops_on_loop_end_without_repeat
    @spu.write16(0xC00 + 0x04, 0x1000) # voice 0 pitch: one decoded sample per SPU tick
    @spu.write16(0xC00 + 0x06, 0)
    write_adpcm_block(0, flags: 0x01)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 28)

    assert_equal 0x0001, @spu.read16(PSX::SPU::ENDX_LOW)
    assert_equal 0, @spu.instance_variable_get(:@voice_active) & 0x0001
  end

  def test_voice_tick_loops_to_repeat_address_when_loop_repeat_is_set
    @spu.write16(0xC00 + 0x04, 0x1000)
    @spu.write16(0xC00 + 0x06, 0)
    @spu.write16(0xC00 + 0x0E, 0x0004)
    write_adpcm_block(0, flags: 0x03)
    write_adpcm_block(4, flags: 0x00, first_data_byte: 0x01)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 28)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0x0001, @spu.read16(PSX::SPU::ENDX_LOW)
    assert_equal 0x0001, @spu.instance_variable_get(:@voice_active) & 0x0001
    assert_equal 0x0004, voice.current_address
    assert_equal 4096, voice.decoded_samples[0]
  end

  def test_loop_start_flag_updates_voice_repeat_address
    @spu.write16(0xC00 + 0x06, 0x0002)
    write_adpcm_block(2, flags: 0x04)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0x0002, voice.repeat_address
  end

  def test_tick_outputs_decoded_voice_pcm_to_sink
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x7FFF)
    @spu.write16(0xC00 + 0x00, 0x7FFF) # voice 0 left volume
    @spu.write16(0xC00 + 0x02, 0x4000) # voice 0 right volume
    @spu.write16(0xC00 + 0x04, 0x1000)
    write_adpcm_block(0, flags: 0x00, first_data_byte: 0x11)
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 2)

    assert_equal [0, 0], frames[0], "first sample uses the reset ADSR level"
    assert_operator frames[1][0], :>, 0
    assert_in_delta frames[1][0] / 2.0, frames[1][1], 2
  end

  def test_tick_advances_basic_adsr_current_volume
    @spu.write16(0xC00 + 0x04, 0x1000)
    write_adpcm_block(0, flags: 0x00, first_data_byte: 0x11)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x3800, @spu.read16(0xC00 + 0x0C)
  end

  def test_attack_rate_7f_holds_adsr_volume
    @spu.write16(0xC00 + 0x04, 0x1000)
    @spu.write16(0xC00 + 0x08, 0x7F00)
    write_adpcm_block(0, flags: 0x00, first_data_byte: 0x11)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 4)

    assert_equal 0, @spu.read16(0xC00 + 0x0C)
  end

  def test_cd_audio_mixes_when_spucnt_cd_audio_enable_is_set
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x7FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x4000)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x2000)
    @spu.queue_cd_audio([4000, -4000].pack("s<*"))

    @spu.write16(PSX::SPU::SPUCNT, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_in_delta 2000, frames.first[0], 1
    assert_in_delta(-1000, frames.first[1], 1)
  end

  def test_main_volume_scales_final_spu_output
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x4000)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x2000)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x7FFF)
    @spu.queue_cd_audio([4000, -4000].pack("s<*"))

    @spu.write16(PSX::SPU::SPUCNT, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_in_delta 2000, frames.first[0], 1
    assert_in_delta(-1000, frames.first[1], 1)
  end

  def test_pitch_modulation_registers_read_back
    @spu.write16(PSX::SPU::PITCH_MOD_LOW, 0x0002)
    @spu.write16(PSX::SPU::PITCH_MOD_HIGH, 0x0040)

    assert_equal 0x0002, @spu.read16(PSX::SPU::PITCH_MOD_LOW)
    assert_equal 0x0040, @spu.read16(PSX::SPU::PITCH_MOD_HIGH)
  end

  def test_pitch_modulation_ignores_voice_zero_bit
    @spu.write16(0xC00 + 0x04, 0x1000)
    write_adpcm_block(0, flags: 0x00)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.write16(PSX::SPU::PITCH_MOD_LOW, 0x0001)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0, voice.sample_counter
    assert_equal 1, voice.sample_index
  end

  def test_pitch_modulation_uses_previous_voice_last_volume
    voices = @spu.instance_variable_get(:@voices)
    voices[0].last_volume = 0x7FFF
    voices[1].decoded_samples = Array.new(28, 0)
    @spu.instance_variable_set(:@voice_active, 0x0002)
    @spu.write16(0xC00 + 0x10 + 0x04, 0x1000)
    @spu.write16(PSX::SPU::PITCH_MOD_LOW, 0x0002)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x0FFF, voices[1].sample_counter
    assert_equal 1, voices[1].sample_index
  end

  def test_pitch_modulation_can_reduce_voice_step
    voices = @spu.instance_variable_get(:@voices)
    voices[0].last_volume = -0x4000
    voices[1].decoded_samples = Array.new(28, 0)
    @spu.instance_variable_set(:@voice_active, 0x0002)
    @spu.write16(0xC00 + 0x10 + 0x04, 0x1000)
    @spu.write16(PSX::SPU::PITCH_MOD_LOW, 0x0002)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x0800, voices[1].sample_counter
    assert_equal 0, voices[1].sample_index
  end

  def test_cd_audio_queue_is_not_consumed_when_spucnt_cd_audio_is_disabled
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x7FFF)
    @spu.queue_cd_audio([1234, 5678].pack("s<*"))

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal [0, 0], frames.first
    assert_equal [1234, 5678], @spu.instance_variable_get(:@cd_audio_fifo)
  end

  def test_clearing_spucnt_enable_forces_active_voices_off
    @spu.write16(0xC00 + 0x0C, 0x4000)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.write16(PSX::SPU::SPUCNT, 1 << 15)

    @spu.write16(PSX::SPU::SPUCNT, 0)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0, @spu.instance_variable_get(:@voice_active)
    assert_equal :off, voice.adsr_phase
    assert_equal 0, @spu.read16(0xC00 + 0x0C)
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

  private

  def write_adpcm_block(address, flags:, first_data_byte: 0)
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, address)
    @spu.dma_write_word((first_data_byte << 16) | (flags << 8))
    3.times { @spu.dma_write_word(0) }
  end
end
