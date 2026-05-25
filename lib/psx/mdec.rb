# frozen_string_literal: true

module PSX
  # MDEC — Motion DECoder.
  #
  # JPEG-style fixed-function decoder. Accepts a stream of RLE'd DCT
  # coefficients, optionally + colour conversion, and emits decoded
  # macroblocks. Used by every retail PSX game with an FMV intro
  # (Rage Racer, Ridge Racer, Crash Bandicoot, etc.).
  #
  # This is the Phase 1 stub from docs/mdec_scoping.md: the bus surface
  # and command-word state machine are wired up so games don't hang on a
  # NULL bus, but the actual IDCT / YCbCr / output formatter haven't
  # landed yet — reads of the output FIFO return zero. The next phase
  # adds the quant/IDCT table loaders + DMA0 ingress so games can at
  # least submit data successfully; phase 3 is the decoder proper.
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

    # Command IDs (high nibble of MDEC0 command word)
    CMD_NOP                = 0
    CMD_DECODE             = 1   # decode N macroblocks; param = data words
    CMD_SET_QUANT_TABLE    = 2   # load luma+chroma quant tables (64+64 bytes)
    CMD_SET_IDCT_TABLE     = 3   # load IDCT scale table (64 × s16 = 128 bytes)
    # 4..7 reserved

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
    end

    # --- Bus interface -----------------------------------------------------

    # Read MDEC0: dequeue from the output FIFO. Phase-1 stub: always empty.
    def read32_data
      @output_fifo.shift || 0
    end

    # Read MDEC1: the live status word.
    def read32_status
      status = 0
      status |= STAT_OUTPUT_FIFO_EMPTY if @output_fifo.empty?
      # STAT_INPUT_FIFO_FULL stays 0 in the stub — we consume writes immediately.
      status |= STAT_COMMAND_BUSY if @params_remaining.positive?
      # DMA0 (data in) requested when DMA0 is enabled AND we're mid-command
      # waiting for more parameter words. DMA1 (out) when DMA1 is enabled
      # AND the output FIFO has data to drain. Both stay 0 in the stub.
      status |= STAT_DATA_IN_REQ  if @dma_in_enabled  && @params_remaining.positive?
      status |= STAT_DATA_OUT_REQ if @dma_out_enabled && !@output_fifo.empty?
      status |= (@output_depth & 0x3) << 25
      status |= (1 << 24) if @output_signed
      status |= (1 << 23) if @output_bit15
      # Bits 15..0 = (param count - 1), clamped to 0xFFFF when no command
      # is pending. Reads of this field are what games poll to know how
      # many words they still owe the decoder.
      remaining_field = @params_remaining.zero? ? 0xFFFF : (@params_remaining - 1)
      status |= remaining_field & 0xFFFF
      status
    end

    # Write MDEC0: command word OR parameter / RLE data word.
    def write32_data(word)
      word &= 0xFFFF_FFFF
      if @params_remaining.zero?
        # New command word.
        @command = (word >> 29) & 0x7
        case @command
        when CMD_DECODE
          # Bits 25..0 = number of parameter words; bits 27-26 = output mode.
          @output_depth  = (word >> 27) & 0x3
          @output_signed = ((word >> 26) & 1) != 0
          @output_bit15  = ((word >> 25) & 1) != 0
          @params_remaining = word & 0xFFFF
        when CMD_SET_QUANT_TABLE
          # Bit 0 = include chroma table (extra 64 bytes). Phase-1: drop.
          @params_remaining = ((word & 1) != 0) ? 32 : 16  # 64+64 or 64 bytes
        when CMD_SET_IDCT_TABLE
          @params_remaining = 32  # 64 × s16 = 128 bytes = 32 words
        else
          # CMD_NOP / unknown — drop, stays idle.
          @params_remaining = 0
        end
      else
        # Parameter / RLE data word. Phase-1 stub: just consume it.
        @params_remaining -= 1
      end
    end

    # Write MDEC1: control register.
    def write32_control(word)
      word &= 0xFFFF_FFFF
      if (word & CTRL_RESET) != 0
        reset
        return
      end
      @dma_in_enabled  = (word & CTRL_ENABLE_DMA_IN)  != 0
      @dma_out_enabled = (word & CTRL_ENABLE_DMA_OUT) != 0
    end
  end
end
