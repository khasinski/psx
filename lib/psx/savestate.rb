# frozen_string_literal: true

# Save / restore the full emulator state to disk. Used both interactively
# (F5/F8 in the SDL window) and by the perf bench so we can time forward
# from a saved game state instead of always replaying BIOS boot.
#
# Each component (CPU, GTE, Memory, GPU, ...) defines state_snapshot and
# restore_state via plain hashes of primitive values. The Emulator-level
# save_state wraps them in a versioned header and serialises with Marshal.
#
# The state file does NOT contain the BIOS bytes (validated against a
# fingerprint instead) nor the CD-ROM disc (the caller re-opens it). Open
# file handles and procs cannot be Marshal'd, so they're explicitly
# excluded from the snapshots.

require "digest"

module PSX
  STATE_MAGIC   = "PSXSTATE"
  STATE_VERSION = 1

  class CPU
    def state_snapshot
      {
        pc: @pc, next_pc: @next_pc, current_pc: @current_pc,
        regs: @regs.dup, hi: @hi, lo: @lo,
        step_cycles: @step_cycles,
        next_in_delay_slot: @next_in_delay_slot,
        branch_target: @branch_target,
        load_delay_reg: @load_delay_reg,
        load_delay_value: @load_delay_value,
        load_delay_commit_reg: @load_delay_commit_reg,
        load_delay_commit_value: @load_delay_commit_value,
        cop0: @cop0.state_snapshot,
        gte: @gte.state_snapshot,
      }
    end

    def restore_state(s)
      @pc = s[:pc]; @next_pc = s[:next_pc]; @current_pc = s[:current_pc]
      @regs = s[:regs].dup; @hi = s[:hi]; @lo = s[:lo]
      @step_cycles = s[:step_cycles]
      @next_in_delay_slot = s[:next_in_delay_slot]
      @branch_target = s[:branch_target]
      @load_delay_reg = s[:load_delay_reg]
      @load_delay_value = s[:load_delay_value]
      @load_delay_commit_reg = s[:load_delay_commit_reg] || 0
      @load_delay_commit_value = s[:load_delay_commit_value] || 0
      @cop0.restore_state(s[:cop0])
      @gte.restore_state(s[:gte])
    end
  end

  class COP0
    def state_snapshot
      { regs: @regs.dup }
    end

    def restore_state(s)
      @regs = s[:regs].dup
    end
  end

  class GTE
    GTE_SCALAR_IVARS = %i[
      otz ir0 ir1 ir2 ir3 res1 mac0 mac1 mac2 mac3 lzcs lzcr
      ofx ofy h dqa dqb zsf3 zsf4 flag op_cycles
    ].freeze
    GTE_VECTOR_IVARS = %i[rgbc sz tr bk fc].freeze
    GTE_MATRIX_IVARS = %i[v sxy rgb_fifo rt ls lc].freeze

    def state_snapshot
      h = {}
      GTE_SCALAR_IVARS.each { |k| h[k] = instance_variable_get(:"@#{k}") }
      GTE_VECTOR_IVARS.each { |k| h[k] = instance_variable_get(:"@#{k}").dup }
      GTE_MATRIX_IVARS.each { |k| h[k] = instance_variable_get(:"@#{k}").map(&:dup) }
      h
    end

    def restore_state(s)
      GTE_SCALAR_IVARS.each do |k|
        v = s[k]
        instance_variable_set(:"@#{k}", v) unless v.nil?
      end
      GTE_VECTOR_IVARS.each { |k| instance_variable_set(:"@#{k}", s[k].dup) }
      GTE_MATRIX_IVARS.each { |k| instance_variable_set(:"@#{k}", s[k].map(&:dup)) }
    end
  end

  class RAM
    def state_snapshot
      # Pack as little-endian u32 binary — ~10x smaller than Marshal'd Array
      # of 512K Integer, and unpack/pack is C-fast.
      { words: @words.pack("V*") }
    end

    def restore_state(s)
      @words = s[:words].unpack("V*")
    end
  end

  class Memory
    def state_snapshot
      {
        ram: @ram.state_snapshot,
        scratchpad: @scratchpad.dup,
        cache_isolated: @cache_isolated,
      }
    end

    def restore_state(s)
      @ram.restore_state(s[:ram])
      # The fast-path inlines in CPU op_lw/op_sw hold a direct reference to
      # @ram's @words array; that reference was rebound to a new Array by
      # RAM#restore_state, so refresh both Memory's mirror and the CPU's.
      @ram_words = @ram.instance_variable_get(:@words)
      @scratchpad = s[:scratchpad].dup
      @cache_isolated = s[:cache_isolated]
    end
  end

  class Interrupts
    def state_snapshot
      { stat: @stat, mask: @mask }
    end

    def restore_state(s)
      @stat = s[:stat]; @mask = s[:mask]
    end
  end

  class DMA
    class Channel
      def state_snapshot
        {
          base_addr: @base_addr, block_ctrl: @block_ctrl,
          channel_ctrl: @channel_ctrl, busy_cycles: @busy_cycles,
          suspended: @suspended,
        }
      end

      def restore_state(s)
        @base_addr = s[:base_addr]
        @block_ctrl = s[:block_ctrl]
        @channel_ctrl = s[:channel_ctrl]
        @busy_cycles = s[:busy_cycles]
        @suspended = s[:suspended]
      end
    end

    def state_snapshot
      {
        channels: @channels.map(&:state_snapshot),
        dpcr: @dpcr, dicr: @dicr,
        master_flag_latched: @master_flag_latched,
        pending_completions: @pending_completions&.dup,
      }
    end

    def restore_state(s)
      s[:channels].each_with_index { |cs, i| @channels[i].restore_state(cs) }
      @dpcr = s[:dpcr]
      @dicr = s[:dicr]
      @master_flag_latched = s[:master_flag_latched]
      @pending_completions = s[:pending_completions]&.dup
    end
  end

  class GPU
    GPU_IVARS = %i[
      status display_enabled display_start_x display_start_y
      display_h_start display_h_end display_v_start display_v_end
      video_mode horizontal_res vertical_res color_depth_24 interlaced
      draw_area_left draw_area_top draw_area_right draw_area_bottom
      draw_offset_x draw_offset_y
      texture_page_x texture_page_y texture_depth semi_transparency
      texture_window_mask_x texture_window_mask_y
      texture_window_offset_x texture_window_offset_y
      texture_x_flip texture_y_flip
      texture_disable_allow set_mask_bit check_mask_bit
      cmd_remaining current_cmd polyline_active
      vram_transfer_x vram_transfer_y vram_transfer_start_x
      vram_transfer_width vram_transfer_height vram_transfer_count
      vram_transfer_mode
      dma_direction odd_field
    ].freeze

    def state_snapshot
      h = { vram: @vram.pack("v*") }  # 1MB, 16-bit per pixel
      GPU_IVARS.each { |k| h[k] = instance_variable_get(:"@#{k}") }
      h[:cmd_buffer] = @cmd_buffer.dup
      h[:vram_read_buffer] = @vram_read_buffer.dup
      h
    end

    def restore_state(s)
      @vram = s[:vram].unpack("v*")
      GPU_IVARS.each { |k| instance_variable_set(:"@#{k}", s[k]) }
      @texture_x_flip = false if @texture_x_flip.nil?
      @texture_y_flip = false if @texture_y_flip.nil?
      @cmd_buffer = s[:cmd_buffer].dup
      @vram_read_buffer = s[:vram_read_buffer].dup
      # Invalidate any cached display frame.
      @framebuffer_dirty = true
      @framebuffer_cache = nil
    end
  end

  class SPU
    def state_snapshot
      {
        ram: @ram.dup, regs: @regs.dup,
        transfer_addr: @transfer_addr, current_addr: @current_addr,
        irq_addr: @irq_addr,
        cnt: @cnt, stat: @stat, dtc: @dtc,
        key_on: @key_on, key_off: @key_off, endx: @endx,
        voice_active: @voice_active,
        main_left_volume: @main_left_volume,
        main_right_volume: @main_right_volume,
        main_left_current_volume: @main_left_current_volume || 0,
        main_right_current_volume: @main_right_current_volume || 0,
        pitch_modulation_enable: @pitch_modulation_enable || 0,
        noise_mode_enable: @noise_mode_enable || 0,
        noise_count: @noise_count || 0,
        noise_level: @noise_level || 1,
        reverb_on_enable: @reverb_on_enable || 0,
        cd_audio_left_volume: @cd_audio_left_volume,
        cd_audio_right_volume: @cd_audio_right_volume,
        cd_audio_fifo: @cd_audio_fifo.dup,
        sample_cycle_accumulator: @sample_cycle_accumulator || 0,
        voices: @voices.map { |v| v.to_h.transform_values { |value| value.is_a?(Array) || value.is_a?(Hash) ? value.dup : value } },
        fifo: @fifo.dup,
      }
    end

    def restore_state(s)
      @ram = s[:ram].dup
      @regs = s[:regs].dup
      @transfer_addr = s[:transfer_addr]
      @current_addr = s[:current_addr]
      @irq_addr = s[:irq_addr] || 0
      @cnt = s[:cnt]; @stat = s[:stat]; @dtc = s[:dtc]
      @key_on = s[:key_on] || 0
      @key_off = s[:key_off] || 0
      @endx = s[:endx] || 0
      @voice_active = s[:voice_active] || 0
      @main_left_volume = s[:main_left_volume] || 0
      @main_right_volume = s[:main_right_volume] || 0
      @main_left_current_volume = s[:main_left_current_volume] || 0
      @main_right_current_volume = s[:main_right_current_volume] || 0
      @pitch_modulation_enable = s[:pitch_modulation_enable] || 0
      @noise_mode_enable = s[:noise_mode_enable] || 0
      @noise_count = s[:noise_count] || 0
      @noise_level = s[:noise_level] || 1
      @reverb_on_enable = s[:reverb_on_enable] || 0
      @cd_audio_left_volume = s[:cd_audio_left_volume] || 0
      @cd_audio_right_volume = s[:cd_audio_right_volume] || 0
      @cd_audio_fifo = s[:cd_audio_fifo]&.dup || []
      @sample_cycle_accumulator = s[:sample_cycle_accumulator] || 0
      if s[:voices]
        @voices = s[:voices].map do |voice|
          SPU::VoiceState.new(
            current_address: voice[:current_address],
            repeat_address: voice[:repeat_address],
            adsr_volume: voice[:adsr_volume],
            adsr_phase: voice[:adsr_phase] || :off,
            adsr_target: voice[:adsr_target] || 0,
            adsr_envelope: (voice[:adsr_envelope] || reset_volume_envelope(0, 0, false, false, false)).dup,
            last_samples: (voice[:last_samples] || [0, 0]).dup,
            decoded_samples: (voice[:decoded_samples] || []).dup,
            current_block_flags: voice[:current_block_flags] || 0,
            sample_index: voice[:sample_index] || 0,
            sample_counter: voice[:sample_counter] || 0,
            last_volume: voice[:last_volume] || 0,
            is_first_block: voice[:is_first_block] || false,
            ignore_loop_address: voice[:ignore_loop_address] || false,
            left_volume: voice[:left_volume] || 0,
            right_volume: voice[:right_volume] || 0
          )
        end
      end
      @fifo = s[:fifo].dup
    end
  end

  class MDEC
    def state_snapshot
      {
        output_depth: @output_depth,
        output_signed: @output_signed,
        output_bit15: @output_bit15,
        dma_in_enabled: @dma_in_enabled,
        dma_out_enabled: @dma_out_enabled,
        command: @command,
        params_remaining: @params_remaining,
        output_fifo: @output_fifo.dup,
        output_words_remaining: @output_words_remaining,
        quant_luma: @quant_luma.dup,
        quant_chroma: @quant_chroma.dup,
        idct_table: @idct_table.dup,
        decode_buffer: @decode_buffer.dup,
        current_block: @current_block,
        load_target: @load_target,
        load_offset: @load_offset,
        load_includes_chroma: @load_includes_chroma,
      }
    end

    def restore_state(s)
      @output_depth = s[:output_depth]
      @output_signed = s[:output_signed]
      @output_bit15 = s[:output_bit15]
      @dma_in_enabled = s[:dma_in_enabled]
      @dma_out_enabled = s[:dma_out_enabled]
      @command = s[:command]
      @params_remaining = s[:params_remaining]
      @output_fifo = s[:output_fifo].dup
      @output_words_remaining = s[:output_words_remaining] || @output_fifo.size
      @quant_luma = s[:quant_luma]&.dup || Array.new(64, 0)
      @quant_chroma = s[:quant_chroma]&.dup || Array.new(64, 0)
      @idct_table = s[:idct_table]&.dup || Array.new(64, 0)
      @decode_buffer = s[:decode_buffer]&.dup || []
      @current_block = s[:current_block] || 0
      @load_target = s[:load_target]
      @load_offset = s[:load_offset] || 0
      @load_includes_chroma = s[:load_includes_chroma]
    end
  end

  class CDROM
    CDROM_SCALAR_IVARS = %i[
      stat index irq_enable irq_flags data_pos seek_lba read_lba
      mode speed_2x xa_enabled xa_filter_file xa_filter_channel
      muted reading want_seek whole_sector sector_cycles sectors_since_read
      read_pending_seek pause_after_first_sector
      bfrd_active cdda_playing cdda_lba cdda_cycles
      last_sector_lba last_sector_header_valid
    ].freeze

    def state_snapshot
      h = {}
      CDROM_SCALAR_IVARS.each { |k| h[k] = instance_variable_get(:"@#{k}") }
      h[:parameters] = @parameters.dup
      h[:response]   = @response.dup
      h[:pending]    = @pending.map(&:dup)
      h[:data_buffer] = @data_buffer&.dup
      h[:last_sector_header] = @last_sector_header.dup
      h[:last_sector_subheader] = @last_sector_subheader.dup
      h[:last_subq] = @last_subq.dup
      h[:last_subq_valid] = @last_subq_valid
      h[:disc_insert_stat_sequence] = @disc_insert_stat_sequence.dup
      h[:xa_last_samples] = @xa_last_samples.dup
      h
    end

    def restore_state(s)
      CDROM_SCALAR_IVARS.each { |k| instance_variable_set(:"@#{k}", s[k]) }
      @parameters = s[:parameters].dup
      @response   = s[:response].dup
      @pending    = s[:pending].map(&:dup)
      @data_buffer = s[:data_buffer]&.dup
      @last_sector_header = s[:last_sector_header]&.dup || [0, 0, 0, 0]
      @last_sector_subheader = s[:last_sector_subheader]&.dup || [0, 0, 0, 0]
      @last_subq = s[:last_subq]&.dup || [0, 0, 0, 0, 0, 0, 0, 0]
      @last_subq_valid = s[:last_subq_valid] || false
      @disc_insert_stat_sequence = s[:disc_insert_stat_sequence]&.dup || []
      @xa_last_samples = s[:xa_last_samples]&.dup || [0, 0, 0, 0]
    end
  end

  class Timers
    class Timer
      def state_snapshot
        { counter: @counter, mode: @mode, target: @target, irq_fired: @irq_fired }
      end

      def restore_state(s)
        @counter = s[:counter]; @mode = s[:mode]
        @target = s[:target]; @irq_fired = s[:irq_fired]
      end
    end

    def state_snapshot
      {
        timers: @timers.map(&:state_snapshot),
        system_counter: @system_counter,
        t0_partial: @t0_partial,
        t1_partial: @t1_partial,
      }
    end

    def restore_state(s)
      s[:timers].each_with_index { |ts, i| @timers[i].restore_state(ts) }
      @system_counter = s[:system_counter]
      @t0_partial = s[:t0_partial]
      @t1_partial = s[:t1_partial]
    end
  end

  class SIO0
    class MemoryCard
      def state_snapshot
        {
          data: @data.pack("C*"),
          state: @state,
          address: @address,
          offset: @offset,
          checksum: @checksum,
          last_byte: @last_byte,
          flag: @flag,
        }
      end

      def restore_state(s)
        @data = s[:data].bytes
        @state = s[:state]
        @address = s[:address]
        @offset = s[:offset]
        @checksum = s[:checksum]
        @last_byte = s[:last_byte]
        @flag = s[:flag]
      end
    end

    def state_snapshot
      {
        ctrl: @ctrl, mode: @mode, baud: @baud,
        rx: @rx.dup,
        irq: @irq,
        device_step: @device_step,
        active_device: @active_device,
        pending_tx: @pending_tx,
        pending_transfer_cycles: @pending_transfer_cycles,
        pending_ack_cycles: @pending_ack_cycles,
        ack_low_cycles: @ack_low_cycles,
        memory_card: @memory_card.state_snapshot,
      }
    end

    def restore_state(s)
      @ctrl = s[:ctrl]; @mode = s[:mode]; @baud = s[:baud]
      @rx = s[:rx].dup
      @irq = s[:irq]
      @device_step = s[:device_step]
      @active_device = s[:active_device]
      @pending_tx = s[:pending_tx]
      @pending_transfer_cycles = s[:pending_transfer_cycles]
      @pending_ack_cycles = s[:pending_ack_cycles]
      @ack_low_cycles = s[:ack_low_cycles] || 0
      @memory_card.restore_state(s[:memory_card]) if s[:memory_card]
    end
  end

  class Emulator
    # Save the full emulator state to `path`. Round-trips with `load_state`
    # to bit-exact identical continued execution. Does not include the BIOS
    # (only a fingerprint) or the CD-ROM (caller must re-load the disc
    # before load_state if the save was taken with a disc inserted).
    def save_state(path)
      payload = {
        magic: STATE_MAGIC,
        version: STATE_VERSION,
        bios_sha1: bios_sha1,
        cycle_count: @cycle_count,
        frame_count: @frame_count,
        cpu: @cpu.state_snapshot,
        memory: @memory.state_snapshot,
        interrupts: @interrupts.state_snapshot,
        dma: @dma.state_snapshot,
        gpu: @gpu.state_snapshot,
        spu: @spu.state_snapshot,
        mdec: @mdec.state_snapshot,
        cdrom: @cdrom.state_snapshot,
        timers: @timers.state_snapshot,
        sio0: @sio0.state_snapshot,
      }
      File.binwrite(path, Marshal.dump(payload))
      path
    end

    def load_state(path)
      data = Marshal.load(File.binread(path))
      raise "not a PSX state file: bad magic #{data[:magic].inspect}" unless data[:magic] == STATE_MAGIC
      unless data[:version] == STATE_VERSION
        raise "state version mismatch: file is v#{data[:version]}, emulator expects v#{STATE_VERSION}"
      end
      unless data[:bios_sha1] == bios_sha1
        raise "BIOS fingerprint mismatch: state was saved with BIOS #{data[:bios_sha1][0, 8]}, " \
              "current BIOS is #{bios_sha1[0, 8]}"
      end

      @cycle_count = data[:cycle_count]
      @frame_count = data[:frame_count]
      @cpu.restore_state(data[:cpu])
      @memory.restore_state(data[:memory])
      @interrupts.restore_state(data[:interrupts])
      @dma.restore_state(data[:dma])
      @gpu.restore_state(data[:gpu])
      @spu.restore_state(data[:spu])
      @mdec.restore_state(data[:mdec]) if data[:mdec]
      @cdrom.restore_state(data[:cdrom])
      @timers.restore_state(data[:timers])
      @sio0.restore_state(data[:sio0])

      # CPU's @ram_words mirror was rebound by Memory#restore_state; reattach
      # so its op_lw/op_sw fast paths read the restored RAM, not the original.
      @cpu.instance_variable_set(:@ram_words, @memory.ram_words)

      self
    end

    # Convenience: construct an emulator from BIOS + (optional) disc, then
    # restore the state. Used by bin/_psx-state-bench so we can time forward
    # from a known-interesting game state without re-running BIOS boot.
    def self.from_state(path, bios:, disc: nil)
      emu = new(bios, disc_path: disc)
      emu.load_state(path)
      emu
    end

    private

    def bios_sha1
      @memory.instance_variable_get(:@bios).instance_variable_get(:@sha1)
    end
  end
end
