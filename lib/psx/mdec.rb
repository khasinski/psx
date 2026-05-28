# frozen_string_literal: true

module PSX
  # MDEC — Motion DECoder.
  #
  # JPEG-style fixed-function decoder. Accepts a stream of RLE'd DCT
  # coefficients, optionally + colour conversion, and emits decoded
  # macroblocks. Used by every retail PSX game with an FMV intro
  # (Rage Racer, Ridge Racer, Crash Bandicoot, etc.).
  #
  # The implementation is intentionally simple rather than cycle-exact:
  # command/data FIFO state, quant/IDCT table loads, DMA ingress/egress, RLE
  # decode, IDCT, colour conversion, and output packing are represented well
  # enough for BIOS, ps1-tests, and retail FMV/texture upload paths.
  #
  # Register layout (offsets from IO_START):
  #   0x820  MDEC0 (write: command + RLE data; read: decoded output)
  #   0x824  MDEC1 (write: control / reset; read: status)
  class MDEC
    # MDEC1 status bits
    STAT_OUTPUT_FIFO_EMPTY = 1 << 31  # 1 = output FIFO has nothing to read
    STAT_INPUT_FIFO_FULL   = 1 << 30  # 1 = data-in FIFO is full
    STAT_COMMAND_BUSY      = 1 << 29  # 1 = decoder currently busy
    STAT_DATA_IN_REQ       = 1 << 28  # 1 = DMA0 should send more
    STAT_DATA_OUT_REQ      = 1 << 27  # 1 = DMA1 can drain
    # bits 26-25 = output colour depth (set from last command 1)
    # bit 24     = output signed (0=unsigned)
    # bit 23     = output bit-15 (mask bit for 15-bit mode)
    # bits 15-0  = number of parameter words remaining (current command)

    # MDEC1 control bits (write side)
    CTRL_RESET             = 1 << 31  # 1 = reset entire decoder
    CTRL_ENABLE_DMA_IN     = 1 << 30  # 1 = enable DMA0 transfer requests
    CTRL_ENABLE_DMA_OUT    = 1 << 29  # 1 = enable DMA1 transfer requests
    OUTPUT_EMPTY_STATUS_DELAY_CYCLES = 4_096

    # Command IDs (high nibble of MDEC0 command word)
    CMD_NOP                = 0
    CMD_DECODE             = 1   # decode N macroblocks; param = data words
    CMD_SET_QUANT_TABLE    = 2   # load luma+chroma quant tables (64+64 bytes)
    CMD_SET_IDCT_TABLE     = 3   # load IDCT scale table (64 × s16 = 128 bytes)
    # 4..7 reserved

    # Zig-zag scan order for an 8x8 DCT block in the row-major coefficient
    # layout consumed by the DuckStation/Mednafen-style IDCT path below.
    ZIGZAG = [
       0,  8,  1,  2,  9, 16, 24, 17,
      10,  3,  4, 11, 18, 25, 32, 40,
      33, 26, 19, 12,  5,  6, 13, 20,
      27, 34, 41, 48, 56, 49, 42, 35,
      28, 21, 14,  7, 15, 22, 29, 36,
      43, 50, 57, 58, 51, 44, 37, 30,
      23, 31, 38, 45, 52, 59, 60, 53,
      46, 39, 47, 54, 61, 62, 55, 63
    ].freeze

    # End-of-block marker in the RLC stream: any halfword equal to 0xFE00
    # terminates the current block (the decoder then advances to the
    # header of the next block). Encoder convention; not a runtime flag.
    RLC_EOB = 0xFE00

    def initialize
      reset
    end

    def reset
      @output_depth     = 0
      @output_signed    = false
      @output_bit15     = false
      @dma_in_enabled   = false
      @dma_out_enabled  = false
      @command          = CMD_NOP
      @params_remaining = 0      # how many more 32-bit words we expect for current command
      # When we actually decode, the output FIFO will hold pixel data; for the
      # phase-1 stub it stays empty so the game sees "FIFO empty" on reads.
      @output_fifo      = []
      @output_empty_status_delay_cycles = 0
      # Quant tables (luma + chroma) and IDCT scale table. Stored when the
      # game loads them; consumed by the decoder in phase 3.
      @quant_luma       = Array.new(64, 0)
      @quant_chroma     = Array.new(64, 0)
      @idct_table       = Array.new(64, 0)
      # Buffer of decode-command parameter words (RLE + scale headers).
      # Phase 3 will consume this and produce pixel data.
      @decode_buffer    = []
      @current_block    = 0
      # Sub-state during a multi-word command load (so write32_data knows
      # what to do with each successive word).
      @load_target      = nil   # :quant_luma | :quant_chroma | :idct | :decode_data | nil
      @load_offset      = 0
      # Phase-2 "honest stub" output: number of output words still
      # available for the game to drain. Set when a decode finishes;
      # decremented on each read. Reads return 0 (no real decoder yet),
      # but at least the DMA-out path completes instead of hanging.
      @output_words_remaining = 0
    end

    # --- Bus interface -----------------------------------------------------

    # Read MDEC0: drain a word from the decoder output FIFO. After Phase 3
    # this returns real decoded pixel data (packed in the format the game
    # requested via the last CMD_DECODE).
    def read32_data
      if @output_words_remaining.positive?
        @output_words_remaining -= 1
        word = @output_fifo.shift || 0
        if @output_words_remaining.zero?
          @output_empty_status_delay_cycles = OUTPUT_EMPTY_STATUS_DELAY_CYCLES
        end
        word
      else
        0xFFFF_FFFF
      end
    end

    # Read MDEC1: the live status word.
    def read32_status
      status = 0
      output_empty = @output_words_remaining.zero? && @output_empty_status_delay_cycles <= 0
      status |= STAT_OUTPUT_FIFO_EMPTY if output_empty
      # STAT_INPUT_FIFO_FULL stays 0 in the stub — we consume writes immediately.
      status |= STAT_COMMAND_BUSY if @params_remaining.positive? || @output_words_remaining.positive?
      status |= STAT_DATA_IN_REQ  if @dma_in_enabled && @params_remaining.positive?
      # DMA1 (out) when DMA1 is enabled AND there's output left to drain.
      status |= STAT_DATA_OUT_REQ if @dma_out_enabled && @output_words_remaining.positive?
      status |= (@output_depth & 0x3) << 25
      status |= (1 << 24) if @output_signed
      status |= (1 << 23) if @output_bit15
      status |= (((@current_block || 0) + 4) % 6) << 16
      # Bits 15..0 = (param count - 1), clamped to 0xFFFF when no command
      # is pending. Reads of this field are what games poll to know how
      # many words they still owe the decoder.
      remaining_field = @params_remaining.zero? ? 0xFFFF : (@params_remaining - 1)
      status |= remaining_field & 0xFFFF
      status
    end

    def data_out_available?
      @output_words_remaining.positive?
    end

    def tick(cycles)
      return if @output_empty_status_delay_cycles <= 0
      @output_empty_status_delay_cycles -= cycles
      @output_empty_status_delay_cycles = 0 if @output_empty_status_delay_cycles < 0
    end

    # Write MDEC0: command word OR parameter / RLE data word.
    def write32_data(word)
      word &= 0xFFFF_FFFF
      if @params_remaining.zero?
        start_command(word)
      else
        consume_payload(word)
        @params_remaining -= 1
        finish_decode if @params_remaining.zero? && @load_target == :decode_data
      end
    end

    # Write MDEC1: control register.
    def write32_control(word)
      word &= 0xFFFF_FFFF
      if (word & CTRL_RESET) != 0
        reset
      end
      @dma_in_enabled  = (word & CTRL_ENABLE_DMA_IN)  != 0
      @dma_out_enabled = (word & CTRL_ENABLE_DMA_OUT) != 0
    end

    private

    def start_command(word)
      @command = (word >> 29) & 0x7
      @output_fifo.clear
      @output_words_remaining = 0
      @output_empty_status_delay_cycles = 0
      @output_depth  = (word >> 27) & 0x3
      @output_signed = ((word >> 26) & 1) != 0
      @output_bit15  = ((word >> 25) & 1) != 0

      case @command
      when CMD_DECODE
        # Bits 27..25 = output mode (depth, signed, bit15). 15..0 = data
        # words to follow. Each one is a 32-bit pair of RLE codes.
        @params_remaining = word & 0xFFFF
        @load_target = :decode_data
        @load_offset = 0
        @decode_buffer.clear
      when CMD_SET_QUANT_TABLE
        # Bit 0 = include chroma table (extra 64 bytes). 64 bytes = 16
        # words; 64+64 = 32 words.
        chroma = (word & 1) != 0
        @params_remaining = chroma ? 32 : 16
        @load_target = :quant_luma
        @load_offset = 0
        @load_includes_chroma = chroma
      when CMD_SET_IDCT_TABLE
        @params_remaining = 32  # 64 × s16 = 128 bytes = 32 words
        @load_target = :idct
        @load_offset = 0
      else
        # Unknown commands still consume their declared parameter words.
        @params_remaining = word & 0xFFFF
        @load_target = :ignore
      end
    end

    def consume_payload(word)
      case @load_target
      when :decode_data
        @decode_buffer << word
      when :quant_luma
        # Each word holds 4 bytes of the table (little-endian).
        4.times do |i|
          idx = @load_offset + i
          next if idx >= 64
          @quant_luma[idx] = (word >> (i * 8)) & 0xFF
        end
        @load_offset += 4
        # After 64 luma bytes, switch to chroma if the command included it.
        if @load_offset == 64 && @load_includes_chroma
          @load_target = :quant_chroma
          @load_offset = 0
        end
      when :quant_chroma
        4.times do |i|
          idx = @load_offset + i
          next if idx >= 64
          @quant_chroma[idx] = (word >> (i * 8)) & 0xFF
        end
        @load_offset += 4
      when :idct
        # Each word holds two signed-16 coefficients (little-endian).
        2.times do |i|
          idx = @load_offset + i
          next if idx >= 64
          raw = (word >> (i * 16)) & 0xFFFF
          transposed_idx = (idx % 8) * 8 + (idx / 8)
          @idct_table[transposed_idx] = (raw & 0x8000) != 0 ? raw - 0x1_0000 : raw
        end
        @load_offset += 2
      end
    end

    # Phase 3: walk the RLC stream submitted via CMD_DECODE, decompress
    # each block (header → RLC pairs → unzig-zag → dequantise → IDCT),
    # assemble macroblocks for 15/24-bit modes (Cr, Cb, 4×Y → YCbCr → RGB),
    # and pack the resulting pixels into the output FIFO in the format
    # the game requested.
    def finish_decode
      halfwords = []
      @decode_buffer.each do |word|
        halfwords << (word & 0xFFFF)
        halfwords << ((word >> 16) & 0xFFFF)
      end

      blocks_per_mb = (@output_depth <= 1) ? 1 : 6
      output_bytes  = []
      pos           = 0

      while pos < halfwords.size
        blocks = []
        blocks_per_mb.times do |bi|
          # Block index decides which quant table to use: 0/1 = chroma
          # (Cr, Cb), 2..5 = luma. 4-bit/8-bit modes only ever have a
          # single Y block so they always use the luma table.
          qtable = if blocks_per_mb == 1 || bi >= 2
                     @quant_luma
                   else
                     @quant_chroma
                   end
          block, pos = decode_block(halfwords, pos, qtable)
          break if block.nil?
          blocks << block
        end
        break if blocks.size < blocks_per_mb

        case @output_depth
        when 0 then pack_4bit_into(output_bytes, blocks[0])
        when 1 then pack_8bit_into(output_bytes, blocks[0])
        when 2 then pack_24bit_into(output_bytes, blocks)
        when 3 then pack_15bit_into(output_bytes, blocks)
        end
      end

      # Pack bytes into 32-bit words (little-endian). MDEC's FIFO words
      # are read by DMA1 in the same order they're produced.
      @output_fifo.clear
      i = 0
      while i < output_bytes.size
        word = (output_bytes[i] || 0) |
               ((output_bytes[i + 1] || 0) << 8) |
               ((output_bytes[i + 2] || 0) << 16) |
               ((output_bytes[i + 3] || 0) << 24)
        @output_fifo << word
        i += 4
      end
      @output_words_remaining = @output_fifo.size
      @output_empty_status_delay_cycles = 0
    end

    # Decode a single 8x8 block. Returns [pixel_block_64ints, new_pos] or
    # [nil, pos] if the stream is truncated.
    def decode_block(halfwords, pos, qtable)
      return [nil, pos] if pos >= halfwords.size

      header = halfwords[pos]
      pos += 1
      while header == RLC_EOB
        return [nil, pos] if pos >= halfwords.size
        header = halfwords[pos]
        pos += 1
      end

      q_scale = (header >> 10) & 0x3F
      dc_raw  = header & 0x3FF
      dc_raw  -= 0x400 if dc_raw >= 0x200   # sign-extend 10-bit

      # Reconstruct dequantised DCT coefficients in natural order. RLC run
      # lengths advance in zig-zag order, while the quant table is indexed by
      # that zig-zag coefficient number as on the hardware.
      coeffs = Array.new(64, 0)
      coeffs[ZIGZAG[0]] = if q_scale.zero?
                            clamp_signed_15(dc_raw << 5)
                          else
                            coeff = (dc_raw * qtable[0]) << 4
                            coeff += dc_raw.positive? ? -8 : 8 if dc_raw != 0
                            clamp_signed_15(coeff)
                          end

      idx = 0
      while pos < halfwords.size
        hw = halfwords[pos]
        pos += 1
        break if hw == RLC_EOB

        run = (hw >> 10) & 0x3F
        val = hw & 0x3FF
        val -= 0x400 if val >= 0x200    # sign-extend 10-bit

        idx += run + 1
        if idx < 64
          coef = if q_scale.zero?
                   val << 5
                 else
                   scq = q_scale * qtable[idx]
                   ((val * scq) >> 3) << 4
                 end
          coef += val.positive? ? -8 : 8 if !q_scale.zero? && val != 0
          coef = clamp_signed_15(coef)
          coeffs[ZIGZAG[idx]] = coef
        end
        break if idx >= 63
      end
      # End-of-stream without an explicit EOB = implicit EOB; emit the
      # partial block we built up. (Some encoders, including the one
      # used for .tests/mdec/4bit/heart.mdec, omit the trailing EOB.)

      [idct_8x8(coeffs), pos]
    end

    # Two-pass integer IDCT following DuckStation's current MDEC path. The
    # RLE decoder keeps four fractional coefficient bits; each row pass
    # rounds with +0x20000 >> 18, then the final value is sign-extended from
    # 9 bits and clamped to the signed byte range used by colour conversion.
    def idct_8x8(coeffs)
      temp = Array.new(64, 0)
      8.times do |x|
        8.times do |y|
          temp[y * 8 + x] = idct_row(coeffs, x * 8, y * 8)
        end
      end

      out = Array.new(64, 0)
      8.times do |x|
        8.times do |y|
          sum = idct_row(temp, x * 8, y * 8)
          out[x * 8 + y] = [[sign_extend_9(sum), -128].max, 127].min
        end
      end
      out
    end

    def idct_row(values, value_offset, scale_offset)
      sum = 0
      8.times do |i|
        sum += values[value_offset + i] * @idct_table[scale_offset + i]
      end
      (sum + 0x2_0000) >> 18
    end

    def sign_extend_9(v)
      v &= 0x1FF
      (v & 0x100) != 0 ? v - 0x200 : v
    end

    def clamp_signed_15(v)
      return -0x4000 if v < -0x4000
      return 0x3FFF if v > 0x3FFF
      v
    end

    # 4-bit indexed output: pack each pixel as a 4-bit nybble, two per
    # byte. The hardware quantises the 9-bit pixel to 4 bits by taking
    # the high nybble of the unsigned value (after +128 bias).
    def pack_4bit_into(output_bytes, block)
      32.times do |i|
        lo = clamp_nybble(block[i * 2])
        hi = clamp_nybble(block[i * 2 + 1])
        output_bytes << (lo | (hi << 4))
      end
    end

    # 8-bit indexed output: pack each pixel as a byte. Signed or unsigned
    # based on output_signed flag.
    def pack_8bit_into(output_bytes, block)
      64.times do |i|
        v = block[i]
        output_bytes << (@output_signed ? (v & 0xFF) : clamp_byte(v + 128))
      end
    end

    # 15-bit RGB output (RGB555 little-endian halfwords). 16x16 macroblock:
    # 4 Y blocks + 1 Cb + 1 Cr (chroma is half-res, upsampled 2x). Two
    # bytes per pixel, 256 pixels = 512 bytes per macroblock.
    def pack_15bit_into(output_bytes, blocks)
      cr, cb, y0, y1, y2, y3 = blocks
      bit15 = @output_bit15 ? 0x8000 : 0
      ys    = [y0, y1, y2, y3]
      ys.each_with_index do |yb, block_index|
        block_x = (block_index & 1) * 8
        block_y = (block_index >> 1) * 8
        8.times do |y|
          8.times do |x|
          yv = yb[y * 8 + x]
          # Chroma is half-resolution across the whole 16x16 macroblock.
          cv = cb[((block_y + y) >> 1) * 8 + ((block_x + x) >> 1)]
          rv = cr[((block_y + y) >> 1) * 8 + ((block_x + x) >> 1)]
          r, g, b = ycbcr_to_rgb(yv, cv, rv)
          pix = rgb888_to_rgb555(r, g, b) | bit15
          output_bytes << (pix & 0xFF)
          output_bytes << ((pix >> 8) & 0xFF)
          end
        end
      end
    end

    # 24-bit RGB output: 3 bytes per pixel, R G B order. Same 16x16
    # macroblock structure as 15-bit.
    def pack_24bit_into(output_bytes, blocks)
      cr, cb, y0, y1, y2, y3 = blocks
      ys = [y0, y1, y2, y3]
      16.times do |y|
        16.times do |x|
          yb = ys[(y >> 3) * 2 + (x >> 3)]
          yv = yb[(y & 7) * 8 + (x & 7)]
          cv = cb[(y >> 1) * 8 + (x >> 1)]
          rv = cr[(y >> 1) * 8 + (x >> 1)]
          r, g, b = ycbcr_to_rgb(yv, cv, rv)
          output_bytes << r << g << b
        end
      end
    end

    # YCbCr -> RGB888 using BT.601 coefficients. Y, Cb, Cr are signed
    # decoder outputs. Unsigned output adds the hardware +128 bias; signed
    # output leaves the signed byte value in two's-complement form.
    def ycbcr_to_rgb(y, cb, cr)
      r = sign_extend_9(y + (((359 * cr) + 0x80) >> 8))
      g = sign_extend_9(y + ((((-88 * cb) & ~0x1F) + ((-183 * cr) & ~0x07) + 0x80) >> 8))
      b = sign_extend_9(y + (((454 * cb) + 0x80) >> 8))
      [output_byte(r), output_byte(g), output_byte(b)]
    end

    def output_byte(v)
      v = [[v, -128].max, 127].min
      @output_signed ? (v & 0xFF) : v + 128
    end

    def rgb888_to_rgb555(r, g, b)
      r5 = [[(r + 4) >> 3, 0x1F].min, 0].max
      g5 = [[(g + 4) >> 3, 0x1F].min, 0].max
      b5 = [[(b + 4) >> 3, 0x1F].min, 0].max
      r5 | (g5 << 5) | (b5 << 10)
    end

    def clamp_byte(v)
      return 0   if v < 0
      return 255 if v > 255
      v
    end

    # Bias signed-9 to unsigned-8, then take the high nybble for 4-bit
    # output. Hardware uses the upper 4 bits of the unsigned-byte form.
    def clamp_nybble(v)
      b = clamp_byte(v + 128)
      (b >> 4) & 0xF
    end
  end
end
