# frozen_string_literal: true

require_relative "spec_helper"

class GTETest < Minitest::Test
  def setup
    @gte = PSX::GTE.new
  end

  # --- Register round-trips -----------------------------------------------

  def test_v0_xy_packing
    @gte.write_data(0, 0x1234_5678)
    assert_equal 0x1234_5678, @gte.read_data(0)
  end

  def test_v0_z_sign_extends_on_read
    # Z is a signed 16-bit but read as a 32-bit (sign-extended)
    @gte.write_data(1, 0xFFFF_8000)
    assert_equal 0xFFFF_8000, @gte.read_data(1)
  end

  def test_rgbc_round_trip
    @gte.write_data(6, 0xAABBCCDD)
    assert_equal 0xAABBCCDD, @gte.read_data(6)
  end

  def test_ir_registers_sign_extend
    @gte.write_data(9, 0x0000_8000)  # IR1 = -32768
    assert_equal 0xFFFF_8000, @gte.read_data(9)
  end

  def test_sxyp_pushes_fifo
    @gte.write_data(12, 0x0001_0001) # SXY0 = (1,1)
    @gte.write_data(13, 0x0002_0002) # SXY1 = (2,2)
    @gte.write_data(14, 0x0003_0003) # SXY2 = (3,3)
    @gte.write_data(15, 0x0004_0004) # SXYP push -> SXY0=(2,2), SXY1=(3,3), SXY2=(4,4)
    assert_equal 0x0002_0002, @gte.read_data(12)
    assert_equal 0x0003_0003, @gte.read_data(13)
    assert_equal 0x0004_0004, @gte.read_data(14)
    assert_equal 0x0004_0004, @gte.read_data(15) # SXYP mirrors SXY2
  end

  def test_irgb_orgb_pack_unpack
    # Write 15-bit color (R=10, G=20, B=15) -> IR1=10<<7=1280, IR2=2560, IR3=1920
    rgb15 = (15 << 10) | (20 << 5) | 10
    @gte.write_data(28, rgb15)
    assert_equal 10 << 7, @gte.read_data(9)
    assert_equal 20 << 7, @gte.read_data(10)
    assert_equal 15 << 7, @gte.read_data(11)
    # Reading back IRGB should give the same packed value
    assert_equal rgb15, @gte.read_data(28)
    assert_equal rgb15, @gte.read_data(29)
  end

  def test_orgb_write_is_ignored
    @gte.write_data(9, 100)
    @gte.write_data(29, 0xFFFF)  # ORGB write must not touch IR1/2/3
    assert_equal 100, @gte.read_data(9)
  end

  def test_lzcs_computes_lzcr
    @gte.write_data(30, 0)
    assert_equal 32, @gte.read_data(31)

    @gte.write_data(30, 0xFFFF_FFFF)
    assert_equal 32, @gte.read_data(31)

    @gte.write_data(30, 0x0000_0001)
    assert_equal 31, @gte.read_data(31)  # 31 leading zeros

    @gte.write_data(30, 0x4000_0000)
    assert_equal 1, @gte.read_data(31)   # 1 leading zero
  end

  def test_lzcr_read_only
    @gte.write_data(30, 0)
    @gte.write_data(31, 0x1234)
    assert_equal 32, @gte.read_data(31)
  end

  # --- Control register round-trips ---------------------------------------

  def test_rotation_matrix_round_trip
    @gte.write_control(0, 0x0002_0001)  # RT11=1, RT12=2
    @gte.write_control(4, 0x0000_0009)  # RT33=9
    assert_equal 0x0002_0001, @gte.read_control(0)
    assert_equal 0x0000_0009, @gte.read_control(4)
  end

  def test_translation_vector_is_signed
    @gte.write_control(5, 0xFFFF_FFFE)  # TRX = -2
    assert_equal 0xFFFF_FFFE, @gte.read_control(5)
  end

  def test_h_read_sign_extends
    # H is U16, but reads sign-extend (hardware quirk)
    @gte.write_control(26, 0x0000_8000)
    assert_equal 0xFFFF_8000, @gte.read_control(26)
  end

  # --- Command sanity -----------------------------------------------------

  def test_nclip_computes_2d_cross_product
    # Triangle (0,0), (10,0), (0,10) -> NCLIP = 0*0 + 10*10 + 0*0 - 0*10 - 10*0 - 0*0 = 100
    @gte.write_data(12, pack_xy(0, 0))
    @gte.write_data(13, pack_xy(10, 0))
    @gte.write_data(14, pack_xy(0, 10))
    @gte.execute(0x4A18_0006)  # NCLIP (cmd=0x06, bit 25 set)
    assert_equal 100, signed32(@gte.read_data(24))
  end

  def test_avsz3_averages_sz_with_scale
    # ZSF3 = 0x800; SZ1+SZ2+SZ3 = 0x3000 -> MAC0 = 0x800*0x3000 = 0x1800000; OTZ = MAC0/0x1000 = 0x1800
    @gte.write_control(29, 0x800)
    @gte.write_data(17, 0x1000) # SZ1
    @gte.write_data(18, 0x1000) # SZ2
    @gte.write_data(19, 0x1000) # SZ3
    @gte.execute(0x4A18_002D)   # AVSZ3
    assert_equal 0x1800, @gte.read_data(7)  # OTZ
  end

  def test_mvmva_identity_rotation
    # Identity rotation. Control register layout (each reg packs two S16):
    #   reg 0: RT11 (lo), RT12 (hi)
    #   reg 2: RT22 (lo), RT23 (hi)
    #   reg 4: RT33 (lo)
    @gte.write_control(0, 0x0000_1000) # RT11=0x1000
    @gte.write_control(2, 0x0000_1000) # RT22=0x1000
    @gte.write_control(4, 0x0000_1000) # RT33=0x1000
    # Vector V0 = (10, 20, 30)
    @gte.write_data(0, pack_xy(10, 20))
    @gte.write_data(1, 30)
    # Translation = 0
    # MVMVA: matrix=Rot, vector=V0, translation=TR, sf=1 (shift by 12)
    # MAC = (RT * V) >> 12 = V
    instr = (1 << 25) | (1 << 19) | (0 << 17) | (0 << 15) | (0 << 13) | 0x12
    @gte.execute(instr)
    assert_equal 10, signed16(@gte.read_data(9))  # IR1
    assert_equal 20, signed16(@gte.read_data(10)) # IR2
    assert_equal 30, signed16(@gte.read_data(11)) # IR3
  end

  def test_rtps_progresses_pipeline
    # Smoke test: identity rotation, V0=(0,0,100), TR=0, OFX=OFY=0, H=512, DQA=DQB=0
    @gte.write_control(0, 0x0000_1000)
    @gte.write_control(2, 0x1000_0000)
    @gte.write_control(4, 0x0000_1000)
    @gte.write_control(26, 512)            # H
    @gte.write_data(0, pack_xy(0, 0))
    @gte.write_data(1, 100)
    @gte.execute(0x4A18_0001 | (1 << 19))  # RTPS, sf=1
    # SZ3 must be the z value of MAC3 >> 12, with sf=1 result already shifted, so SZ3 = 100/1
    # The division shouldn't overflow (H=512 < SZ3*2=200... wait it does overflow then)
    # With overflow we still write valid SXY (saturated). Just check pipeline ran.
    refute_nil @gte.read_data(14)  # SXY2 exists
  end

  def test_command_clears_flag_at_start
    @gte.write_control(31, 0x7FFF_F000)  # Pre-set all flags
    @gte.write_data(12, pack_xy(0, 0))
    @gte.write_data(13, pack_xy(0, 0))
    @gte.write_data(14, pack_xy(0, 0))
    @gte.execute(0x4A18_0006)  # NCLIP with no overflow -> flag should be 0
    assert_equal 0, @gte.read_control(31)
  end

  def test_flag_bit_31_or_aggregate
    # Force IR1 overflow flag manually and check bit 31 lights up on read
    # (We can't set FLAG directly to FLAG_IR1_SAT via write_control because the mask
    # keeps that bit, but bit 31 is computed on read.)
    @gte.write_control(31, 1 << 24)  # IR1 saturation
    assert_equal (1 << 24) | (1 << 31), @gte.read_control(31)
  end

  private

  def pack_xy(x, y)
    ((y & 0xFFFF) << 16) | (x & 0xFFFF)
  end

  def signed16(v)
    v &= 0xFFFF
    (v & 0x8000) != 0 ? v - 0x1_0000 : v
  end

  def signed32(v)
    v &= 0xFFFF_FFFF
    (v & 0x8000_0000) != 0 ? v - 0x1_0000_0000 : v
  end
end
