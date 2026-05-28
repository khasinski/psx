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

  def test_key_on_and_key_off_registers_clear_after_sample_tick
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.write16(PSX::SPU::KEY_OFF_LOW, 0x0001)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0, @spu.read16(PSX::SPU::KEY_ON_LOW)
    assert_equal 0, @spu.read16(PSX::SPU::KEY_ON_HIGH)
    assert_equal 0, @spu.read16(PSX::SPU::KEY_OFF_LOW)
    assert_equal 0, @spu.read16(PSX::SPU::KEY_OFF_HIGH)
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
    @spu.write16(0xC00 + 0x06, 0x0200)
    @spu.write16(0xC00 + 0x0E, 0x0204)
    write_adpcm_block(0x0200, flags: 0x03)
    write_adpcm_block(0x0204, flags: 0x00, first_data_byte: 0x01)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 28)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0x0001, @spu.read16(PSX::SPU::ENDX_LOW)
    assert_equal 0x0001, @spu.instance_variable_get(:@voice_active) & 0x0001
    assert_equal 0x0204, voice.current_address
    assert_equal 4096, voice.decoded_samples[0]
  end

  def test_loop_start_flag_updates_voice_repeat_address
    @spu.write16(0xC00 + 0x06, 0x0002)
    write_adpcm_block(2, flags: 0x04)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0x0002, voice.repeat_address
  end

  def test_active_repeat_address_write_updates_live_voice
    @spu.write16(0xC00 + 0x06, 0x0000)
    write_adpcm_block(0, flags: 0x00)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    @spu.write16(0xC00 + 0x0E, 0x0005)

    voice = @spu.instance_variable_get(:@voices)[0]
    assert_equal 0x0004, voice.repeat_address
  end

  def test_repeat_address_write_after_first_block_ignores_later_loop_start_flag
    @spu.write16(0xC00 + 0x06, 0x0000)
    write_adpcm_block(0, flags: 0x00)
    write_adpcm_block(2, flags: 0x04)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    voice = @spu.instance_variable_get(:@voices)[0]
    voice.is_first_block = false
    voice.current_address = 0x0002

    @spu.write16(0xC00 + 0x0E, 0x0004)
    @spu.send(:decode_voice_block, 0)

    assert_equal 0x0004, voice.repeat_address
  end

  def test_tick_outputs_decoded_voice_pcm_to_sink
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x3FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x3FFF)
    @spu.write16(0xC00 + 0x00, 0x3FFF) # voice 0 left volume
    @spu.write16(0xC00 + 0x02, 0x2000) # voice 0 right volume
    @spu.write16(0xC00 + 0x04, 0x1000)
    write_adpcm_block(0, flags: 0x00, first_data_byte: 0x11)
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }

    @spu.write16(PSX::SPU::SPUCNT, 1 << 14)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 2)

    assert_equal [0, 0], frames[0], "first sample uses the reset ADSR level"
    assert_operator frames[1][0], :>, 0
    assert_in_delta frames[1][0] / 2.0, frames[1][1], 2
  end

  def test_spucnt_mute_bit_silences_voice_mix
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x3FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x3FFF)
    @spu.write16(0xC00 + 0x00, 0x3FFF)
    @spu.write16(0xC00 + 0x02, 0x3FFF)
    @spu.write16(0xC00 + 0x04, 0x1000)
    @spu.write16(0xC00 + 0x0C, 0x7FFF)
    write_adpcm_block(0x0200, flags: 0x00, first_data_byte: 0x11)
    @spu.write16(0xC00 + 0x06, 0x0200)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.write16(0xC00 + 0x0C, 0x7FFF)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal [0, 0], frames.first
  end

  def test_spucnt_mute_bit_clears_voice_reverb_input_but_keeps_cd_audio
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    voices = @spu.instance_variable_get(:@voices)
    voices[0].adsr_volume = 0x7FFF
    voices[0].adsr_phase = :sustain
    voices[0].decoded_samples = Array.new(28, 4000)
    @spu.instance_variable_set(:@voice_active, 0x0001)
    @spu.write16(0xC00 + 0x00, 0x3FFF)
    @spu.write16(0xC00 + 0x02, 0x3FFF)
    @spu.write16(0xC00 + 0x04, 0x0001)
    @spu.write16(PSX::SPU::REVERB_ON_LOW, 0x0001)
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x3FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x3FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x7FFF)
    @spu.queue_cd_audio([3000, -3000].pack("s<*"))

    @spu.write16(PSX::SPU::SPUCNT, 0x0001 | (1 << 2))
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_in_delta 3000, frames.first[0], 2
    assert_in_delta(-3000, frames.first[1], 2)
    assert_in_delta 3000, @spu.instance_variable_get(:@last_reverb_input)[0], 2
    assert_in_delta(-3000, @spu.instance_variable_get(:@last_reverb_input)[1], 2)
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

  def test_active_adsr_low_write_updates_attack_envelope
    @spu.write16(0xC00 + 0x04, 0x1000)
    @spu.write16(0xC00 + 0x08, 0x7F00)
    write_adpcm_block(0, flags: 0x00, first_data_byte: 0x11)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    @spu.write16(0xC00 + 0x08, 0x0000)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x3800, @spu.read16(0xC00 + 0x0C)
  end

  def test_adsr_current_volume_write_updates_live_voice_volume
    @spu.write16(0xC00 + 0x04, 0x0001)
    write_adpcm_block(0, flags: 0x00, first_data_byte: 0x11)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    @spu.write16(0xC00 + 0x0C, 0x4000)

    assert_equal 0x4000, @spu.instance_variable_get(:@voices)[0].adsr_volume
  end

  def test_cd_audio_mixes_when_spucnt_cd_audio_enable_is_set
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x3FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x3FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x4000)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x2000)
    @spu.queue_cd_audio([4000, -4000].pack("s<*"))

    @spu.write16(PSX::SPU::SPUCNT, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_in_delta 2000, frames.first[0], 1
    assert_in_delta(-1000, frames.first[1], 1)
  end

  def test_tick_writes_spu_capture_buffers
    voices = @spu.instance_variable_get(:@voices)
    voices[1].last_volume = 1111
    voices[3].last_volume = -2222
    @spu.queue_cd_audio([1234, -2345].pack("s<*"))
    @spu.write16(PSX::SPU::SPUCNT, 0x0001)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 1234, @spu.send(:read_ram_s16, 0x000)
    assert_equal(-2345, @spu.send(:read_ram_s16, 0x400))
    assert_equal 1111, @spu.send(:read_ram_s16, 0x800)
    assert_equal(-2222, @spu.send(:read_ram_s16, 0xC00))
    assert_equal 2, @spu.instance_variable_get(:@capture_buffer_position)
  end

  def test_capture_buffer_position_updates_spustat_second_half_bit
    @spu.instance_variable_set(:@capture_buffer_position, 0x1FE)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x200, @spu.instance_variable_get(:@capture_buffer_position)
    assert_equal 1 << 11, @spu.read16(PSX::SPU::SPUSTAT) & (1 << 11)
  end

  def test_external_volume_registers_read_back
    @spu.write16(PSX::SPU::EXTERNAL_VOL_LEFT, 0x1357)
    @spu.write16(PSX::SPU::EXTERNAL_VOL_RIGHT, 0x2468)

    assert_equal 0x1357, @spu.read16(PSX::SPU::EXTERNAL_VOL_LEFT)
    assert_equal 0x2468, @spu.read16(PSX::SPU::EXTERNAL_VOL_RIGHT)
  end

  def test_main_volume_scales_final_spu_output
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x2000)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x1000)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x7FFF)
    @spu.queue_cd_audio([4000, -4000].pack("s<*"))

    @spu.write16(PSX::SPU::SPUCNT, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_in_delta 2000, frames.first[0], 1
    assert_in_delta(-1000, frames.first[1], 1)
  end

  def test_fixed_volume_writes_update_current_volume_registers
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x3FFF)
    @spu.write16(0xC00, 0x4000)
    @spu.write16(0xC02, 0x7FFF)

    assert_equal 0x3FFF, @spu.read16(PSX::SPU::MAIN_VOL_LEFT)
    assert_equal 0x7FFE, @spu.read16(PSX::SPU::CURRENT_MAIN_VOL_LEFT)
    assert_equal 0x8000, @spu.read16(PSX::SPU::CURRENT_VOICE_VOL_BASE)
    assert_equal 0xFFFE, @spu.read16(PSX::SPU::CURRENT_VOICE_VOL_BASE + 2)
  end

  def test_main_volume_sweep_ticks_current_volume
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x0000)
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x8000)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x3800, @spu.read16(PSX::SPU::CURRENT_MAIN_VOL_LEFT)
  end

  def test_current_main_volume_writes_update_live_volume
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_LEFT, 0x7FFF)
    @spu.write16(PSX::SPU::CD_AUDIO_VOL_RIGHT, 0x7FFF)
    @spu.queue_cd_audio([4000, 4000].pack("s<*"))

    @spu.write16(PSX::SPU::CURRENT_MAIN_VOL_LEFT, 0x4000)
    @spu.write16(PSX::SPU::CURRENT_MAIN_VOL_RIGHT, 0xC000)
    @spu.write16(PSX::SPU::SPUCNT, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x4000, @spu.read16(PSX::SPU::CURRENT_MAIN_VOL_LEFT)
    assert_equal 0xC000, @spu.read16(PSX::SPU::CURRENT_MAIN_VOL_RIGHT)
    assert_in_delta 2000, frames.first[0], 1
    assert_in_delta(-2000, frames.first[1], 1)
  end

  def test_voice_volume_sweep_ticks_current_volume
    @spu.write16(0xC00, 0x0000)
    @spu.write16(0xC00, 0x8000)
    @spu.write16(0xC00 + 0x04, 0x0001)
    write_adpcm_block(0, flags: 0x00)
    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_equal 0x3800, @spu.read16(PSX::SPU::CURRENT_VOICE_VOL_BASE)
  end

  def test_pitch_modulation_registers_read_back
    @spu.write16(PSX::SPU::PITCH_MOD_LOW, 0x0002)
    @spu.write16(PSX::SPU::PITCH_MOD_HIGH, 0x0040)

    assert_equal 0x0002, @spu.read16(PSX::SPU::PITCH_MOD_LOW)
    assert_equal 0x0040, @spu.read16(PSX::SPU::PITCH_MOD_HIGH)
  end

  def test_noise_mode_registers_read_back
    @spu.write16(PSX::SPU::NOISE_MODE_LOW, 0x1357)
    @spu.write16(PSX::SPU::NOISE_MODE_HIGH, 0x0024)

    assert_equal 0x1357, @spu.read16(PSX::SPU::NOISE_MODE_LOW)
    assert_equal 0x0024, @spu.read16(PSX::SPU::NOISE_MODE_HIGH)
  end

  def test_reverb_on_registers_read_back
    @spu.write16(PSX::SPU::REVERB_ON_LOW, 0x2468)
    @spu.write16(PSX::SPU::REVERB_ON_HIGH, 0x0080)

    assert_equal 0x2468, @spu.read16(PSX::SPU::REVERB_ON_LOW)
    assert_equal 0x0080, @spu.read16(PSX::SPU::REVERB_ON_HIGH)
  end

  def test_reverb_parameter_registers_read_back
    @spu.write16(PSX::SPU::REVERB_VOL_LEFT, 0x1111)
    @spu.write16(PSX::SPU::REVERB_VOL_RIGHT, 0x2222)
    @spu.write16(PSX::SPU::REVERB_BASE, 0x3333)
    @spu.write16(PSX::SPU::REVERB_REG_BASE, 0x4444)
    @spu.write16(PSX::SPU::REVERB_REG_END - 2, 0x5555)

    assert_equal 0x1111, @spu.read16(PSX::SPU::REVERB_VOL_LEFT)
    assert_equal 0x2222, @spu.read16(PSX::SPU::REVERB_VOL_RIGHT)
    assert_equal 0x3333, @spu.read16(PSX::SPU::REVERB_BASE)
    assert_equal 0x4444, @spu.read16(PSX::SPU::REVERB_REG_BASE)
    assert_equal 0x5555, @spu.read16(PSX::SPU::REVERB_REG_END - 2)
  end

  def test_reverb_output_tap_mixes_from_spu_ram
    frames = []
    @spu.pcm_sink = ->(bytes) { frames << bytes.unpack("s<*") }
    @spu.write16(PSX::SPU::MAIN_VOL_LEFT, 0x3FFF)
    @spu.write16(PSX::SPU::MAIN_VOL_RIGHT, 0x3FFF)
    @spu.write16(PSX::SPU::REVERB_VOL_LEFT, 0x3FFF)
    @spu.write16(PSX::SPU::REVERB_VOL_RIGHT, 0x2000)
    @spu.write16(PSX::SPU::REVERB_BASE, 0x0100)
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, 0x0100)
    @spu.dma_write_word((4000 << 16) | 4000)

    @spu.write16(PSX::SPU::SPUCNT, (1 << 14) | (1 << 7))
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_in_delta 2000, @spu.instance_variable_get(:@last_reverb_output)[0], 1
    assert_in_delta 1000, @spu.instance_variable_get(:@last_reverb_output)[1], 1
    assert_in_delta 2000, frames.first[0], 2
    assert_in_delta 1000, frames.first[1], 2
  end

  def test_reverb_enabled_voice_sends_to_reverb_input
    voices = @spu.instance_variable_get(:@voices)
    voice = voices[0]
    voice.adsr_volume = 0x7FFF
    voice.adsr_phase = :sustain
    voice.decoded_samples = Array.new(28, 4000)
    @spu.instance_variable_set(:@voice_active, 0x0001)
    @spu.write16(0xC00 + 0x00, 0x3FFF)
    @spu.write16(0xC00 + 0x02, 0x2000)
    @spu.write16(0xC00 + 0x04, 0x0001)
    @spu.write16(PSX::SPU::REVERB_ON_LOW, 0x0001)
    @spu.write16(PSX::SPU::SPUCNT, (1 << 14) | (1 << 7))

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    left, right = @spu.instance_variable_get(:@last_reverb_input)
    assert_operator left, :>, 3900
    assert_operator right, :>, 1900
  end

  def test_reverb_current_address_advances_on_odd_resample_phase
    @spu.write16(PSX::SPU::REVERB_BASE, 0x0100)
    start = @spu.instance_variable_get(:@reverb_current_address)
    @spu.write16(PSX::SPU::SPUCNT, 1 << 7)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)
    assert_equal start, @spu.instance_variable_get(:@reverb_current_address)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)
    assert_equal start + 1, @spu.instance_variable_get(:@reverb_current_address)
    assert_equal 2, @spu.instance_variable_get(:@reverb_resample_position)
  end

  def test_reverb_memory_address_wraps_inside_work_area
    @spu.write16(PSX::SPU::REVERB_BASE, 0x1000)
    @spu.instance_variable_set(:@reverb_current_address, 0x3FFFF)

    assert_equal 0x8000, @spu.send(:reverb_memory_address, 1)
  end

  def test_state_snapshot_preserves_noise_and_reverb_voice_masks
    @spu.write16(PSX::SPU::NOISE_MODE_LOW, 0x1357)
    @spu.write16(PSX::SPU::NOISE_MODE_HIGH, 0x0024)
    @spu.write16(PSX::SPU::REVERB_ON_LOW, 0x2468)
    @spu.write16(PSX::SPU::REVERB_ON_HIGH, 0x0080)
    @spu.write16(PSX::SPU::REVERB_VOL_LEFT, 0x1111)
    @spu.write16(PSX::SPU::REVERB_VOL_RIGHT, 0x2222)
    @spu.write16(PSX::SPU::REVERB_BASE, 0x3333)
    @spu.write16(PSX::SPU::REVERB_REG_BASE + 4, 0x4444)
    @spu.write16(PSX::SPU::EXTERNAL_VOL_LEFT, 0x5555)
    @spu.write16(PSX::SPU::EXTERNAL_VOL_RIGHT, 0x6666)
    @spu.instance_variable_set(:@reverb_current_address, 0x7778)
    @spu.instance_variable_set(:@reverb_resample_position, 0x12)
    @spu.instance_variable_set(:@last_reverb_input, [111, 222])
    @spu.instance_variable_set(:@last_reverb_output, [333, 444])
    @spu.instance_variable_set(:@capture_buffer_position, 0x222)
    @spu.instance_variable_set(:@noise_count, 0x1234_5678)
    @spu.instance_variable_set(:@noise_level, 0x0000_4000)

    restored = PSX::SPU.new
    restored.restore_state(@spu.state_snapshot)

    assert_equal 0x1357, restored.read16(PSX::SPU::NOISE_MODE_LOW)
    assert_equal 0x0024, restored.read16(PSX::SPU::NOISE_MODE_HIGH)
    assert_equal 0x2468, restored.read16(PSX::SPU::REVERB_ON_LOW)
    assert_equal 0x0080, restored.read16(PSX::SPU::REVERB_ON_HIGH)
    assert_equal 0x1111, restored.read16(PSX::SPU::REVERB_VOL_LEFT)
    assert_equal 0x2222, restored.read16(PSX::SPU::REVERB_VOL_RIGHT)
    assert_equal 0x3333, restored.read16(PSX::SPU::REVERB_BASE)
    assert_equal 0x4444, restored.read16(PSX::SPU::REVERB_REG_BASE + 4)
    assert_equal 0x5555, restored.read16(PSX::SPU::EXTERNAL_VOL_LEFT)
    assert_equal 0x6666, restored.read16(PSX::SPU::EXTERNAL_VOL_RIGHT)
    assert_equal 0x7778, restored.instance_variable_get(:@reverb_current_address)
    assert_equal 0x12, restored.instance_variable_get(:@reverb_resample_position)
    assert_equal [111, 222], restored.instance_variable_get(:@last_reverb_input)
    assert_equal [333, 444], restored.instance_variable_get(:@last_reverb_output)
    assert_equal 0x222, restored.instance_variable_get(:@capture_buffer_position)
    assert_equal 0x1234_5678, restored.instance_variable_get(:@noise_count)
    assert_equal 0x0000_4000, restored.instance_variable_get(:@noise_level)
  end

  def test_noise_enabled_voice_uses_noise_level_instead_of_adpcm_sample
    voices = @spu.instance_variable_get(:@voices)
    voice = voices[0]
    voice.adsr_volume = 0x7FFF
    voice.adsr_phase = :sustain
    voice.decoded_samples = Array.new(28, 0)
    @spu.instance_variable_set(:@voice_active, 0x0001)
    @spu.instance_variable_set(:@noise_level, 0x4000)
    @spu.write16(0xC00 + 0x04, 0x0001)
    @spu.write16(PSX::SPU::NOISE_MODE_LOW, 0x0001)

    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE)

    assert_operator voice.last_volume, :>, 0
  end

  def test_noise_enabled_voice_ignores_loop_end_mute_flag
    @spu.write16(0xC00 + 0x04, 0x1000)
    @spu.write16(PSX::SPU::NOISE_MODE_LOW, 0x0001)
    write_adpcm_block(0, flags: 0x01)

    @spu.write16(PSX::SPU::KEY_ON_LOW, 0x0001)
    @spu.tick(PSX::SPU::CYCLES_PER_SAMPLE * 28)

    assert_equal 0x0001, @spu.read16(PSX::SPU::ENDX_LOW)
    assert_equal 0x0001, @spu.instance_variable_get(:@voice_active) & 0x0001
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

  def test_spustat_reports_dma_write_request_in_dma_write_mode
    @spu.write16(PSX::SPU::SPUCNT, PSX::SPU::MODE_DMA_W << 4)

    status = @spu.read16(PSX::SPU::SPUSTAT)

    assert_equal (1 << 7) | (1 << 9), status & ((1 << 7) | (1 << 8) | (1 << 9))
  end

  def test_spustat_clears_dma_request_bits_outside_dma_modes
    @spu.write16(PSX::SPU::SPUCNT, PSX::SPU::MODE_DMA_W << 4)

    @spu.write16(PSX::SPU::SPUCNT, PSX::SPU::MODE_MANUAL << 4)

    assert_equal 0, @spu.read16(PSX::SPU::SPUSTAT) & ((1 << 7) | (1 << 8) | (1 << 9))
  end

  private

  def write_adpcm_block(address, flags:, first_data_byte: 0)
    @spu.write16(PSX::SPU::SPU_TRANSFER_ADDR, address)
    @spu.dma_write_word((first_data_byte << 16) | (flags << 8))
    3.times { @spu.dma_write_word(0) }
  end
end
