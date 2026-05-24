# frozen_string_literal: true

module PSX
  # Geometry Transformation Engine (COP2).
  #
  # 32 data registers, 32 control registers, ~24 commands.
  # Register and flag semantics follow the Nocash PSX spec.
  # Math is implemented straightforwardly (not bit-exact with the hardware UNR
  # divide table), which is enough to get the BIOS boot animation moving.
  class GTE
    # FLAG bits
    FLAG_IR0_SAT          = 1 << 12
    FLAG_SY2_SAT          = 1 << 13
    FLAG_SX2_SAT          = 1 << 14
    FLAG_MAC0_NEG         = 1 << 15
    FLAG_MAC0_POS         = 1 << 16
    FLAG_DIVIDE_OVERFLOW  = 1 << 17
    FLAG_SZ3_OTZ_SAT      = 1 << 18
    FLAG_COLOR_B_SAT      = 1 << 19
    FLAG_COLOR_G_SAT      = 1 << 20
    FLAG_COLOR_R_SAT      = 1 << 21
    FLAG_IR3_SAT          = 1 << 22
    FLAG_IR2_SAT          = 1 << 23
    FLAG_IR1_SAT          = 1 << 24
    FLAG_MAC3_NEG         = 1 << 25
    FLAG_MAC2_NEG         = 1 << 26
    FLAG_MAC1_NEG         = 1 << 27
    FLAG_MAC3_POS         = 1 << 28
    FLAG_MAC2_POS         = 1 << 29
    FLAG_MAC1_POS         = 1 << 30
    # Bit 31: OR of bits 30..23 and 18..13
    FLAG_ERROR_MASK       = ((0xFF) << 23) | ((0x3F) << 13)

    # Per-channel flag-bit lookup tables. mac_set / check_mac_overflow /
    # sat_ir are called 3x per RTPS (and 9x per RTPT); the per-call case
    # dispatch to pick FLAG_MACi_POS etc. showed up in the profile, so we
    # use a constant-array load instead. Index 0 is unused (channels are
    # 1-indexed).
    MAC_POS_FLAGS = [nil, FLAG_MAC1_POS, FLAG_MAC2_POS, FLAG_MAC3_POS].freeze
    MAC_NEG_FLAGS = [nil, FLAG_MAC1_NEG, FLAG_MAC2_NEG, FLAG_MAC3_NEG].freeze
    IR_SAT_FLAGS  = [nil, FLAG_IR1_SAT,  FLAG_IR2_SAT,  FLAG_IR3_SAT].freeze
    COLOR_FLAGS   = [FLAG_COLOR_R_SAT, FLAG_COLOR_G_SAT, FLAG_COLOR_B_SAT].freeze

    def initialize
      reset
    end

    def reset
      # Data registers (logical)
      @v   = Array.new(3) { [0, 0, 0] }   # V0..V2 (S16 X,Y,Z each)
      @rgbc = [0, 0, 0, 0]                 # R, G, B, CODE (U8 each)
      @otz = 0                              # U16
      @ir0 = 0                              # S16
      @ir1 = 0; @ir2 = 0; @ir3 = 0          # S16 each
      @sxy = Array.new(3) { [0, 0] }       # SXY0..SXY2 (S16 X,Y)
      @sz  = [0, 0, 0, 0]                  # SZ0..SZ3 (U16)
      @rgb_fifo = Array.new(3) { [0, 0, 0, 0] }  # RGB0..RGB2 (R,G,B,CD)
      @res1 = 0                             # prohibited
      @mac0 = 0                             # S32
      @mac1 = 0; @mac2 = 0; @mac3 = 0       # S32 each (logically S44 between ops)
      @lzcs = 0                             # S32
      @lzcr = 32                            # leading sign-bit count of LZCS (1..32)

      # Control registers (logical)
      @rt = Array.new(3) { [0, 0, 0] }     # Rotation matrix 3x3, S16
      @tr = [0, 0, 0]                       # Translation, S32 each
      @ls = Array.new(3) { [0, 0, 0] }     # Light source matrix, S16
      @bk = [0, 0, 0]                       # Background color, S32
      @lc = Array.new(3) { [0, 0, 0] }     # Light color matrix, S16
      @fc = [0, 0, 0]                       # Far color, S32
      @ofx = 0                              # S32
      @ofy = 0                              # S32
      @h   = 0                              # U16
      @dqa = 0                              # S16
      @dqb = 0                              # S32
      @zsf3 = 0                             # S16
      @zsf4 = 0                             # S16
      @flag = 0                             # U32
    end

    # --- Public register access ---------------------------------------------

    def read_data(idx)
      case idx & 0x1F
      when 0  then pack_xy(@v[0][0], @v[0][1])
      when 1  then to_u32(sign_extend16(@v[0][2]))
      when 2  then pack_xy(@v[1][0], @v[1][1])
      when 3  then to_u32(sign_extend16(@v[1][2]))
      when 4  then pack_xy(@v[2][0], @v[2][1])
      when 5  then to_u32(sign_extend16(@v[2][2]))
      when 6  then pack_rgbc(@rgbc)
      when 7  then @otz & 0xFFFF
      when 8  then to_u32(sign_extend16(@ir0))
      when 9  then to_u32(sign_extend16(@ir1))
      when 10 then to_u32(sign_extend16(@ir2))
      when 11 then to_u32(sign_extend16(@ir3))
      when 12 then pack_xy(@sxy[0][0], @sxy[0][1])
      when 13 then pack_xy(@sxy[1][0], @sxy[1][1])
      when 14 then pack_xy(@sxy[2][0], @sxy[2][1])
      when 15 then pack_xy(@sxy[2][0], @sxy[2][1])  # SXYP mirror of SXY2
      when 16 then @sz[0] & 0xFFFF
      when 17 then @sz[1] & 0xFFFF
      when 18 then @sz[2] & 0xFFFF
      when 19 then @sz[3] & 0xFFFF
      when 20 then pack_rgbc(@rgb_fifo[0])
      when 21 then pack_rgbc(@rgb_fifo[1])
      when 22 then pack_rgbc(@rgb_fifo[2])
      when 23 then @res1 & 0xFFFF_FFFF
      when 24 then to_u32(@mac0)
      when 25 then to_u32(@mac1)
      when 26 then to_u32(@mac2)
      when 27 then to_u32(@mac3)
      when 28, 29 then pack_irgb
      when 30 then to_u32(@lzcs)
      when 31 then @lzcr & 0xFFFF_FFFF
      end
    end

    def write_data(idx, value)
      v = value & 0xFFFF_FFFF
      case idx & 0x1F
      when 0
        @v[0][0] = sign16(v & 0xFFFF); @v[0][1] = sign16((v >> 16) & 0xFFFF)
      when 1
        @v[0][2] = sign16(v & 0xFFFF)
      when 2
        @v[1][0] = sign16(v & 0xFFFF); @v[1][1] = sign16((v >> 16) & 0xFFFF)
      when 3
        @v[1][2] = sign16(v & 0xFFFF)
      when 4
        @v[2][0] = sign16(v & 0xFFFF); @v[2][1] = sign16((v >> 16) & 0xFFFF)
      when 5
        @v[2][2] = sign16(v & 0xFFFF)
      when 6
        @rgbc = unpack_rgbc(v)
      when 7
        @otz = v & 0xFFFF
      when 8  then @ir0 = sign16(v & 0xFFFF)
      when 9  then @ir1 = sign16(v & 0xFFFF)
      when 10 then @ir2 = sign16(v & 0xFFFF)
      when 11 then @ir3 = sign16(v & 0xFFFF)
      when 12
        @sxy[0][0] = sign16(v & 0xFFFF); @sxy[0][1] = sign16((v >> 16) & 0xFFFF)
      when 13
        @sxy[1][0] = sign16(v & 0xFFFF); @sxy[1][1] = sign16((v >> 16) & 0xFFFF)
      when 14
        @sxy[2][0] = sign16(v & 0xFFFF); @sxy[2][1] = sign16((v >> 16) & 0xFFFF)
      when 15
        # SXYP: writing pushes the FIFO (SXY0 <- SXY1, SXY1 <- SXY2, SXY2 <- new)
        slot = @sxy[0]
        @sxy[0] = @sxy[1]
        @sxy[1] = @sxy[2]
        @sxy[2] = slot
        slot[0] = sign16(v & 0xFFFF)
        slot[1] = sign16((v >> 16) & 0xFFFF)
      when 16 then @sz[0] = v & 0xFFFF
      when 17 then @sz[1] = v & 0xFFFF
      when 18 then @sz[2] = v & 0xFFFF
      when 19 then @sz[3] = v & 0xFFFF
      when 20 then @rgb_fifo[0] = unpack_rgbc(v)
      when 21 then @rgb_fifo[1] = unpack_rgbc(v)
      when 22 then @rgb_fifo[2] = unpack_rgbc(v)
      when 23 then @res1 = v
      when 24 then @mac0 = sign32(v)
      when 25 then @mac1 = sign32(v)
      when 26 then @mac2 = sign32(v)
      when 27 then @mac3 = sign32(v)
      when 28
        # IRGB write: unpack RGB555, each component << 7 into IR1/2/3
        @ir1 = ((v >>  0) & 0x1F) << 7
        @ir2 = ((v >>  5) & 0x1F) << 7
        @ir3 = ((v >> 10) & 0x1F) << 7
      when 29
        # ORGB is read-only
      when 30
        @lzcs = sign32(v)
        @lzcr = leading_sign_bits(@lzcs)
      when 31
        # LZCR is read-only
      end
    end

    def read_control(idx)
      case idx & 0x1F
      when 0  then pack_xy(@rt[0][0], @rt[0][1])
      when 1  then pack_xy(@rt[0][2], @rt[1][0])
      when 2  then pack_xy(@rt[1][1], @rt[1][2])
      when 3  then pack_xy(@rt[2][0], @rt[2][1])
      when 4  then to_u32(sign_extend16(@rt[2][2]))
      when 5  then to_u32(@tr[0])
      when 6  then to_u32(@tr[1])
      when 7  then to_u32(@tr[2])
      when 8  then pack_xy(@ls[0][0], @ls[0][1])
      when 9  then pack_xy(@ls[0][2], @ls[1][0])
      when 10 then pack_xy(@ls[1][1], @ls[1][2])
      when 11 then pack_xy(@ls[2][0], @ls[2][1])
      when 12 then to_u32(sign_extend16(@ls[2][2]))
      when 13 then to_u32(@bk[0])
      when 14 then to_u32(@bk[1])
      when 15 then to_u32(@bk[2])
      when 16 then pack_xy(@lc[0][0], @lc[0][1])
      when 17 then pack_xy(@lc[0][2], @lc[1][0])
      when 18 then pack_xy(@lc[1][1], @lc[1][2])
      when 19 then pack_xy(@lc[2][0], @lc[2][1])
      when 20 then to_u32(sign_extend16(@lc[2][2]))
      when 21 then to_u32(@fc[0])
      when 22 then to_u32(@fc[1])
      when 23 then to_u32(@fc[2])
      when 24 then to_u32(@ofx)
      when 25 then to_u32(@ofy)
      # H is unsigned 16-bit, but hardware sign-extends on read.
      when 26 then to_u32(sign_extend16(@h))
      when 27 then to_u32(sign_extend16(@dqa))
      when 28 then to_u32(@dqb)
      when 29 then to_u32(sign_extend16(@zsf3))
      when 30 then to_u32(sign_extend16(@zsf4))
      when 31
        # Bit 31 = OR of error-flag bits
        flag = @flag & ~(1 << 31)
        flag |= (1 << 31) if (flag & FLAG_ERROR_MASK) != 0
        flag
      end
    end

    def write_control(idx, value)
      v = value & 0xFFFF_FFFF
      case idx & 0x1F
      when 0
        @rt[0][0] = sign16(v & 0xFFFF); @rt[0][1] = sign16((v >> 16) & 0xFFFF)
      when 1
        @rt[0][2] = sign16(v & 0xFFFF); @rt[1][0] = sign16((v >> 16) & 0xFFFF)
      when 2
        @rt[1][1] = sign16(v & 0xFFFF); @rt[1][2] = sign16((v >> 16) & 0xFFFF)
      when 3
        @rt[2][0] = sign16(v & 0xFFFF); @rt[2][1] = sign16((v >> 16) & 0xFFFF)
      when 4
        @rt[2][2] = sign16(v & 0xFFFF)
      when 5  then @tr[0] = sign32(v)
      when 6  then @tr[1] = sign32(v)
      when 7  then @tr[2] = sign32(v)
      when 8
        @ls[0][0] = sign16(v & 0xFFFF); @ls[0][1] = sign16((v >> 16) & 0xFFFF)
      when 9
        @ls[0][2] = sign16(v & 0xFFFF); @ls[1][0] = sign16((v >> 16) & 0xFFFF)
      when 10
        @ls[1][1] = sign16(v & 0xFFFF); @ls[1][2] = sign16((v >> 16) & 0xFFFF)
      when 11
        @ls[2][0] = sign16(v & 0xFFFF); @ls[2][1] = sign16((v >> 16) & 0xFFFF)
      when 12 then @ls[2][2] = sign16(v & 0xFFFF)
      when 13 then @bk[0] = sign32(v)
      when 14 then @bk[1] = sign32(v)
      when 15 then @bk[2] = sign32(v)
      when 16
        @lc[0][0] = sign16(v & 0xFFFF); @lc[0][1] = sign16((v >> 16) & 0xFFFF)
      when 17
        @lc[0][2] = sign16(v & 0xFFFF); @lc[1][0] = sign16((v >> 16) & 0xFFFF)
      when 18
        @lc[1][1] = sign16(v & 0xFFFF); @lc[1][2] = sign16((v >> 16) & 0xFFFF)
      when 19
        @lc[2][0] = sign16(v & 0xFFFF); @lc[2][1] = sign16((v >> 16) & 0xFFFF)
      when 20 then @lc[2][2] = sign16(v & 0xFFFF)
      when 21 then @fc[0] = sign32(v)
      when 22 then @fc[1] = sign32(v)
      when 23 then @fc[2] = sign32(v)
      when 24 then @ofx = sign32(v)
      when 25 then @ofy = sign32(v)
      when 26 then @h   = v & 0xFFFF
      when 27 then @dqa = sign16(v & 0xFFFF)
      when 28 then @dqb = sign32(v)
      when 29 then @zsf3 = sign16(v & 0xFFFF)
      when 30 then @zsf4 = sign16(v & 0xFFFF)
      when 31
        # Bit 31 is read-only (auto-OR). Bits 30..12 writable; lower bits zero.
        @flag = v & 0x7FFF_F000
      end
    end

    # --- Command dispatch ---------------------------------------------------

    # Per-opcode cycle counts from nocash. Bumped into CPU.step_cycles after
    # each GTE command so timer-sensitive code (and amidog's psxtest_gte
    # OFFICIAL.TIMING column) sees realistic GTE durations. Unimplemented
    # opcodes default to 1 cycle.
    OPCODE_CYCLES = {
      0x01 => 15,  # RTPS
      0x06 => 8,   # NCLIP
      0x0C => 6,   # OP
      0x10 => 8,   # DPCS
      0x11 => 8,   # INTPL
      0x12 => 8,   # MVMVA
      0x13 => 19,  # NCDS
      0x14 => 13,  # CDP
      0x16 => 44,  # NCDT
      0x1B => 17,  # NCCS
      0x1C => 11,  # CC
      0x1E => 14,  # NCS
      0x20 => 30,  # NCT
      0x28 => 5,   # SQR
      0x29 => 8,   # DCPL
      0x2A => 17,  # DPCT
      0x2D => 5,   # AVSZ3
      0x2E => 6,   # AVSZ4
      0x30 => 23,  # RTPT
      0x3D => 5,   # GPF
      0x3E => 5,   # GPL
      0x3F => 39   # NCCT
    }.freeze

    attr_reader :op_cycles

    # Run a GTE command instruction (the lower 26 bits of the COP2 imm25 op).
    def execute(instruction)
      @flag = 0  # cleared at the start of each command
      sf = ((instruction >> 19) & 1) != 0  # shift-fraction (12) flag
      lm = ((instruction >> 10) & 1) != 0  # saturate IR1..3 to [0..7FFF]
      mx = (instruction >> 17) & 3
      mv = (instruction >> 15) & 3
      cv = (instruction >> 13) & 3
      shift = sf ? 12 : 0
      opcode = instruction & 0x3F

      case opcode
      when 0x01 then cmd_rtps(0, shift, lm, push_sxy: true)
      when 0x06 then cmd_nclip
      when 0x0C then cmd_op(shift, lm)
      when 0x10 then cmd_dpcs(shift, lm, @rgbc)
      when 0x11 then cmd_intpl(shift, lm)
      when 0x12 then cmd_mvmva(shift, lm, mx, mv, cv)
      when 0x13 then cmd_ncds(0, shift, lm)
      when 0x14 then cmd_cdp(shift, lm)
      when 0x16 then cmd_ncdt(shift, lm)
      when 0x1B then cmd_nccs(0, shift, lm)
      when 0x1C then cmd_cc(shift, lm)
      when 0x1E then cmd_ncs(0, shift, lm)
      when 0x20 then cmd_nct(shift, lm)
      when 0x28 then cmd_sqr(shift, lm)
      when 0x29 then cmd_dcpl(shift, lm)
      when 0x2A then cmd_dpct(shift, lm)
      when 0x2D then cmd_avsz3
      when 0x2E then cmd_avsz4
      when 0x30 then cmd_rtpt(shift, lm)
      when 0x3D then cmd_gpf(shift, lm)
      when 0x3E then cmd_gpl(shift, lm)
      when 0x3F then cmd_ncct(shift, lm)
      else
        # Unimplemented command: leave state alone; flag stays clear.
      end

      # Auto-set bit 31 (error flag)
      @flag |= (1 << 31) if (@flag & FLAG_ERROR_MASK) != 0

      @op_cycles = OPCODE_CYCLES[opcode] || 1
    end

    # --- Helpers: bit-width conversion --------------------------------------

    private

    def to_u32(v); v & 0xFFFF_FFFF; end

    def sign16(v)
      v &= 0xFFFF
      (v & 0x8000) != 0 ? v - 0x1_0000 : v
    end

    def sign32(v)
      v &= 0xFFFF_FFFF
      (v & 0x8000_0000) != 0 ? v - 0x1_0000_0000 : v
    end

    def sign_extend16(v)
      v &= 0xFFFF
      (v & 0x8000) != 0 ? (v | 0xFFFF_0000) : v
    end

    def pack_xy(x, y)
      ((y & 0xFFFF) << 16) | (x & 0xFFFF)
    end

    def pack_rgbc(rgbc)
      r, g, b, c = rgbc
      ((c & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)
    end

    def unpack_rgbc(v)
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]
    end

    def pack_irgb
      r = (@ir1 >> 7).clamp(0, 0x1F)
      g = (@ir2 >> 7).clamp(0, 0x1F)
      b = (@ir3 >> 7).clamp(0, 0x1F)
      (b << 10) | (g << 5) | r
    end

    # Count number of leading sign-bits in value (1..32). For LZCS/LZCR.
    def leading_sign_bits(v)
      v &= 0xFFFF_FFFF
      bit = (v >> 31) & 1
      count = 1
      shifted = (v << 1) & 0xFFFF_FFFF
      31.times do
        break if ((shifted >> 31) & 1) != bit
        count += 1
        shifted = (shifted << 1) & 0xFFFF_FFFF
      end
      count
    end

    # --- Helpers: saturation / overflow flags -------------------------------

    # 43-bit signed overflow detection on MAC1/2/3 values. Kept around for
    # any caller that doesn't know the channel at compile time; the hot path
    # uses the per-channel specialisations (mac_set1/2/3) below which inline
    # the FLAG bit constants directly.
    def check_mac_overflow(i, v)
      @flag |= MAC_POS_FLAGS[i] if v >= 0x80_0000_0000  # 1 << 43
      @flag |= MAC_NEG_FLAGS[i] if v < -0x80_0000_0000
    end

    # 31-bit signed overflow detection on MAC0.
    def check_mac0_overflow(v)
      lim = 1 << 31
      @flag |= FLAG_MAC0_POS if v >= lim
      @flag |= FLAG_MAC0_NEG if v < -lim
    end

    # Saturate value to S16 range, with optional LM (clamp to [0..7FFF]).
    # Returns saturated value and sets the appropriate IRx flag.
    def sat_ir(i, v, lm)
      lo = lm ? 0 : -0x8000
      if v < lo
        @flag |= IR_SAT_FLAGS[i]; lo
      elsif v > 0x7FFF
        @flag |= IR_SAT_FLAGS[i]; 0x7FFF
      else
        v
      end
    end

    def sat_ir0(v)
      if v < 0
        @flag |= FLAG_IR0_SAT; 0
      elsif v > 0x1000
        @flag |= FLAG_IR0_SAT; 0x1000
      else
        v
      end
    end

    def sat_sz3(v)
      if v < 0
        @flag |= FLAG_SZ3_OTZ_SAT; 0
      elsif v > 0xFFFF
        @flag |= FLAG_SZ3_OTZ_SAT; 0xFFFF
      else
        v
      end
    end

    def sat_sxy_x(v)
      if v < -0x400
        @flag |= FLAG_SX2_SAT; -0x400
      elsif v > 0x3FF
        @flag |= FLAG_SX2_SAT; 0x3FF
      else
        v
      end
    end

    def sat_sxy_y(v)
      if v < -0x400
        @flag |= FLAG_SY2_SAT; -0x400
      elsif v > 0x3FF
        @flag |= FLAG_SY2_SAT; 0x3FF
      else
        v
      end
    end

    def sat_color(channel, v)
      if v < 0
        @flag |= COLOR_FLAGS[channel]; 0
      elsif v > 0xFF
        @flag |= COLOR_FLAGS[channel]; 0xFF
      else
        v
      end
    end

    # --- Helpers: FIFO pushes -----------------------------------------------

    def push_sz(value)
      @sz[0] = @sz[1]
      @sz[1] = @sz[2]
      @sz[2] = @sz[3]
      @sz[3] = sat_sz3(value)
    end

    # Rotate the FIFO references and reuse the oldest slot for the new
    # value, so the push doesn't allocate a fresh [x, y] / [r, g, b, c]
    # pair on every call. Profiling the GTE micro-bench showed 97% of
    # samples in GC; almost all of it was the two pushes here multiplied
    # by millions of RTPT/NCDS calls.
    def push_sxy(x, y)
      slot = @sxy[0]
      @sxy[0] = @sxy[1]
      @sxy[1] = @sxy[2]
      @sxy[2] = slot
      slot[0] = sat_sxy_x(x)
      slot[1] = sat_sxy_y(y)
    end

    def push_rgb_from_mac
      slot = @rgb_fifo[0]
      @rgb_fifo[0] = @rgb_fifo[1]
      @rgb_fifo[1] = @rgb_fifo[2]
      @rgb_fifo[2] = slot
      slot[0] = sat_color(0, @mac1 >> 4)
      slot[1] = sat_color(1, @mac2 >> 4)
      slot[2] = sat_color(2, @mac3 >> 4)
      slot[3] = @rgbc[3]
    end

    # --- Helpers: math primitives -------------------------------------------

    # Simplified UNR divide: returns saturated quotient, sets divide flag on
    # overflow. Real hardware uses an 8-bit Newton-Raphson approximation table;
    # we just divide normally, which is close enough for boot.
    def unr_divide
      # nocash: N = ((H * 20000h / SZ3) + 1) / 2, clamped to 17-bit.
      # The trailing /2 is the part that takes N from a 2.16 quotient back
      # into the 1.16 fixed point the projection formula expects — without
      # it every projected vertex was twice as far from OFX/OFY as it
      # should be, which made the BIOS PS logo render at 2x scale.
      if @h < @sz[3] * 2 && @sz[3] != 0
        n = ((@h.to_i * 0x20000 / @sz[3]) + 1) / 2
        return n < 0x1FFFF ? n : 0x1FFFF
      end
      @flag |= FLAG_DIVIDE_OVERFLOW
      0x1FFFF
    end

    # MAC1/2/3 := (a + b + c + d) >> shift, then IR1/2/3 := saturate(MACi).
    # Per-channel specialisations: each call site knows which channel it's
    # writing to, so we avoid a case-on-i for the FLAG bits and the MAC/IR
    # ivars. The hot loop (cmd_rtps, light_normal, light_color) calls these
    # three at a time so the savings compound.
    def mac_set1(accum, shift, lm)
      @flag |= FLAG_MAC1_POS if accum >= 0x80_0000_0000
      @flag |= FLAG_MAC1_NEG if accum < -0x80_0000_0000
      result = accum >> shift
      @mac1 = sign32(result & 0xFFFF_FFFF)
      lo = lm ? 0 : -0x8000
      @ir1 = if result < lo
               @flag |= FLAG_IR1_SAT; lo
             elsif result > 0x7FFF
               @flag |= FLAG_IR1_SAT; 0x7FFF
             else
               result
             end
      result
    end

    def mac_set2(accum, shift, lm)
      @flag |= FLAG_MAC2_POS if accum >= 0x80_0000_0000
      @flag |= FLAG_MAC2_NEG if accum < -0x80_0000_0000
      result = accum >> shift
      @mac2 = sign32(result & 0xFFFF_FFFF)
      lo = lm ? 0 : -0x8000
      @ir2 = if result < lo
               @flag |= FLAG_IR2_SAT; lo
             elsif result > 0x7FFF
               @flag |= FLAG_IR2_SAT; 0x7FFF
             else
               result
             end
      result
    end

    def mac_set3(accum, shift, lm)
      @flag |= FLAG_MAC3_POS if accum >= 0x80_0000_0000
      @flag |= FLAG_MAC3_NEG if accum < -0x80_0000_0000
      result = accum >> shift
      @mac3 = sign32(result & 0xFFFF_FFFF)
      lo = lm ? 0 : -0x8000
      @ir3 = if result < lo
               @flag |= FLAG_IR3_SAT; lo
             elsif result > 0x7FFF
               @flag |= FLAG_IR3_SAT; 0x7FFF
             else
               result
             end
      result
    end

    def sign_to_64(v)
      v &= 0xFFFF_FFFF_FFFF_FFFF
      (v & 0x8000_0000_0000_0000) != 0 ? v - 0x1_0000_0000_0000_0000 : v
    end

    # --- Commands -----------------------------------------------------------

    def cmd_rtps(vi, shift, lm, push_sxy:)
      vx, vy, vz = @v[vi]
      rt = @rt
      rt0 = rt[0]; rt1 = rt[1]; rt2 = rt[2]
      tr = @tr

      ax = (tr[0] << 12) + rt0[0] * vx + rt0[1] * vy + rt0[2] * vz
      ay = (tr[1] << 12) + rt1[0] * vx + rt1[1] * vy + rt1[2] * vz
      az = (tr[2] << 12) + rt2[0] * vx + rt2[1] * vy + rt2[2] * vz

      mac_set1(ax, shift, lm)
      mac_set2(ay, shift, lm)
      # SZ FIFO push uses the unshifted-by-sf result; if sf=0 we still shift by 12.
      mac_set3(az, shift, lm)
      sz_value = (az >> 12)
      push_sz(sz_value)

      n = unr_divide

      mac0 = n * @ir1 + @ofx
      check_mac0_overflow(mac0)
      sx = mac0 >> 16
      mac0 = n * @ir2 + @ofy
      check_mac0_overflow(mac0)
      sy = mac0 >> 16
      push_sxy(sx, sy) if push_sxy

      mac0 = n * @dqa + @dqb
      check_mac0_overflow(mac0)
      @mac0 = sign32(mac0 & 0xFFFF_FFFF)
      @ir0 = sat_ir0(mac0 >> 12)
    end

    def cmd_rtpt(shift, lm)
      cmd_rtps(0, shift, lm, push_sxy: true)
      cmd_rtps(1, shift, lm, push_sxy: true)
      cmd_rtps(2, shift, lm, push_sxy: true)
    end

    def cmd_nclip
      sx0, sy0 = @sxy[0]
      sx1, sy1 = @sxy[1]
      sx2, sy2 = @sxy[2]
      result = sx0 * sy1 + sx1 * sy2 + sx2 * sy0 - sx0 * sy2 - sx1 * sy0 - sx2 * sy1
      check_mac0_overflow(result)
      @mac0 = sign32(result & 0xFFFF_FFFF)
    end

    def cmd_avsz3
      sum = @sz[1] + @sz[2] + @sz[3]
      result = @zsf3 * sum
      check_mac0_overflow(result)
      @mac0 = sign32(result & 0xFFFF_FFFF)
      @otz = sat_sz3(result >> 12) & 0xFFFF
    end

    def cmd_avsz4
      sum = @sz[0] + @sz[1] + @sz[2] + @sz[3]
      result = @zsf4 * sum
      check_mac0_overflow(result)
      @mac0 = sign32(result & 0xFFFF_FFFF)
      @otz = sat_sz3(result >> 12) & 0xFFFF
    end

    # MAC = M * V + T;  IR = saturate(MAC)
    def cmd_mvmva(shift, lm, mx_sel, mv_sel, cv_sel)
      mx = case mx_sel
           when 0 then @rt
           when 1 then @ls
           when 2 then @lc
           else        @rt  # garbage matrix not modeled
           end

      mv = case mv_sel
           when 0 then @v[0]
           when 1 then @v[1]
           when 2 then @v[2]
           else        [@ir1, @ir2, @ir3]
           end

      tv = case cv_sel
           when 0 then @tr
           when 1 then @bk
           when 2 then @fc   # bugged on real HW, we just use as translation
           else        [0, 0, 0]
           end

      a0 = (tv[0] << 12) + mx[0][0] * mv[0] + mx[0][1] * mv[1] + mx[0][2] * mv[2]
      a1 = (tv[1] << 12) + mx[1][0] * mv[0] + mx[1][1] * mv[1] + mx[1][2] * mv[2]
      a2 = (tv[2] << 12) + mx[2][0] * mv[0] + mx[2][1] * mv[1] + mx[2][2] * mv[2]

      mac_set1(a0, shift, lm)
      mac_set2(a1, shift, lm)
      mac_set3(a2, shift, lm)
    end

    def cmd_op(shift, lm)
      d1 = @rt[0][0]; d2 = @rt[1][1]; d3 = @rt[2][2]
      a1 = @ir3 * d2 - @ir2 * d3
      a2 = @ir1 * d3 - @ir3 * d1
      a3 = @ir2 * d1 - @ir1 * d2
      mac_set1(a1, shift, lm)
      mac_set2(a2, shift, lm)
      mac_set3(a3, shift, lm)
    end

    def cmd_sqr(shift, lm)
      mac_set1(@ir1 * @ir1, shift, lm)
      mac_set2(@ir2 * @ir2, shift, lm)
      mac_set3(@ir3 * @ir3, shift, lm)
    end

    def cmd_dpcs(shift, lm, color)
      r, g, b, _cd = color
      a1 = (r << 16) + (((@fc[0] << 12) - (r << 16)) >> shift) * 0  # simplified
      # MAC = COLOR<<16; then interpolate toward FC by IR0.
      mac1_in = r << 16
      mac2_in = g << 16
      mac3_in = b << 16
      # Interpolation: MAC = MAC + (FC<<12 - MAC) * IR0  (approximation)
      mac1_in += (((@fc[0] << 12) - mac1_in) >> shift) * @ir0
      mac2_in += (((@fc[1] << 12) - mac2_in) >> shift) * @ir0
      mac3_in += (((@fc[2] << 12) - mac3_in) >> shift) * @ir0
      mac_set1(mac1_in, shift, lm)
      mac_set2(mac2_in, shift, lm)
      mac_set3(mac3_in, shift, lm)
      push_rgb_from_mac
    end

    def cmd_dpct(shift, lm)
      3.times { cmd_dpcs(shift, lm, @rgb_fifo[0]) }
    end

    def cmd_intpl(shift, lm)
      mac1_in = (@ir1 << 12)
      mac2_in = (@ir2 << 12)
      mac3_in = (@ir3 << 12)
      mac1_in += (((@fc[0] << 12) - mac1_in) >> shift) * @ir0
      mac2_in += (((@fc[1] << 12) - mac2_in) >> shift) * @ir0
      mac3_in += (((@fc[2] << 12) - mac3_in) >> shift) * @ir0
      mac_set1(mac1_in, shift, lm)
      mac_set2(mac2_in, shift, lm)
      mac_set3(mac3_in, shift, lm)
      push_rgb_from_mac
    end

    # Normal color light source: MAC := LS * V
    def light_normal(vi, shift, lm)
      vx, vy, vz = @v[vi]
      ls = @ls
      ls0 = ls[0]; ls1 = ls[1]; ls2 = ls[2]
      mac_set1(ls0[0] * vx + ls0[1] * vy + ls0[2] * vz, shift, lm)
      mac_set2(ls1[0] * vx + ls1[1] * vy + ls1[2] * vz, shift, lm)
      mac_set3(ls2[0] * vx + ls2[1] * vy + ls2[2] * vz, shift, lm)
    end

    # Background + LightColor * IR
    def light_color(shift, lm)
      lc = @lc
      lc0 = lc[0]; lc1 = lc[1]; lc2 = lc[2]
      bk = @bk
      ir1 = @ir1; ir2 = @ir2; ir3 = @ir3
      mac_set1((bk[0] << 12) + lc0[0] * ir1 + lc0[1] * ir2 + lc0[2] * ir3, shift, lm)
      mac_set2((bk[1] << 12) + lc1[0] * ir1 + lc1[1] * ir2 + lc1[2] * ir3, shift, lm)
      mac_set3((bk[2] << 12) + lc2[0] * ir1 + lc2[1] * ir2 + lc2[2] * ir3, shift, lm)
    end

    def cmd_ncs(vi, shift, lm)
      light_normal(vi, shift, lm)
      light_color(shift, lm)
      push_rgb_from_mac
    end

    def cmd_nct(shift, lm)
      cmd_ncs(0, shift, lm)
      cmd_ncs(1, shift, lm)
      cmd_ncs(2, shift, lm)
    end

    def cmd_nccs(vi, shift, lm)
      light_normal(vi, shift, lm)
      light_color(shift, lm)
      r, g, b, _ = @rgbc
      mac_set1((r * @ir1) << 4, shift, lm)
      mac_set2((g * @ir2) << 4, shift, lm)
      mac_set3((b * @ir3) << 4, shift, lm)
      push_rgb_from_mac
    end

    def cmd_ncct(shift, lm)
      cmd_nccs(0, shift, lm)
      cmd_nccs(1, shift, lm)
      cmd_nccs(2, shift, lm)
    end

    def cmd_ncds(vi, shift, lm)
      light_normal(vi, shift, lm)
      light_color(shift, lm)
      r, g, b, _ = @rgbc
      # Distance-color interpolation toward FC, weighted by IR0.
      mac1_in = (r * @ir1) << 4
      mac2_in = (g * @ir2) << 4
      mac3_in = (b * @ir3) << 4
      mac1_in += (((@fc[0] << 12) - mac1_in) >> shift) * @ir0
      mac2_in += (((@fc[1] << 12) - mac2_in) >> shift) * @ir0
      mac3_in += (((@fc[2] << 12) - mac3_in) >> shift) * @ir0
      mac_set1(mac1_in, shift, lm)
      mac_set2(mac2_in, shift, lm)
      mac_set3(mac3_in, shift, lm)
      push_rgb_from_mac
    end

    def cmd_ncdt(shift, lm)
      cmd_ncds(0, shift, lm)
      cmd_ncds(1, shift, lm)
      cmd_ncds(2, shift, lm)
    end

    def cmd_cc(shift, lm)
      r, g, b, _ = @rgbc
      light_color(shift, lm)
      mac_set1((r * @ir1) << 4, shift, lm)
      mac_set2((g * @ir2) << 4, shift, lm)
      mac_set3((b * @ir3) << 4, shift, lm)
      push_rgb_from_mac
    end

    def cmd_cdp(shift, lm)
      r, g, b, _ = @rgbc
      light_color(shift, lm)
      mac1_in = (r * @ir1) << 4
      mac2_in = (g * @ir2) << 4
      mac3_in = (b * @ir3) << 4
      mac1_in += (((@fc[0] << 12) - mac1_in) >> shift) * @ir0
      mac2_in += (((@fc[1] << 12) - mac2_in) >> shift) * @ir0
      mac3_in += (((@fc[2] << 12) - mac3_in) >> shift) * @ir0
      mac_set1(mac1_in, shift, lm)
      mac_set2(mac2_in, shift, lm)
      mac_set3(mac3_in, shift, lm)
      push_rgb_from_mac
    end

    def cmd_dcpl(shift, lm)
      r, g, b, _ = @rgbc
      mac1_in = (r * @ir1) << 4
      mac2_in = (g * @ir2) << 4
      mac3_in = (b * @ir3) << 4
      mac1_in += (((@fc[0] << 12) - mac1_in) >> shift) * @ir0
      mac2_in += (((@fc[1] << 12) - mac2_in) >> shift) * @ir0
      mac3_in += (((@fc[2] << 12) - mac3_in) >> shift) * @ir0
      mac_set1(mac1_in, shift, lm)
      mac_set2(mac2_in, shift, lm)
      mac_set3(mac3_in, shift, lm)
      push_rgb_from_mac
    end

    def cmd_gpf(shift, lm)
      mac_set1(@ir0 * @ir1, shift, lm)
      mac_set2(@ir0 * @ir2, shift, lm)
      mac_set3(@ir0 * @ir3, shift, lm)
      push_rgb_from_mac
    end

    def cmd_gpl(shift, lm)
      mac_set1((@mac1 << shift) + @ir0 * @ir1, shift, lm)
      mac_set2((@mac2 << shift) + @ir0 * @ir2, shift, lm)
      mac_set3((@mac3 << shift) + @ir0 * @ir3, shift, lm)
      push_rgb_from_mac
    end
  end
end
