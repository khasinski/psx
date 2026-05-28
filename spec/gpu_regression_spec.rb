# frozen_string_literal: true

require_relative "spec_helper"

class GPURegressionSpec < Minitest::Test
  include TestHelpers

  def setup
    @gpu = create_gpu
  end

  def test_polyline_consumes_terminator_without_desync
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_20_20)

    @gpu.gp0(0x48_00_FF_00) # monochrome polyline
    @gpu.gp0(0x0000_0000)
    @gpu.gp0(0x0000_0004)
    @gpu.gp0(0x0004_0004)
    @gpu.gp0(0x5555_5555)

    @gpu.gp0(0x68_00_00_FF) # fixed 1x1 rectangle, should parse cleanly
    @gpu.gp0(0x0008_0008)

    assert_equal 0x001F, @gpu.vram[8 + 8 * PSX::GPU::VRAM_WIDTH]
    assert_equal 0x03E0, @gpu.vram[0], "polyline should draw before the terminator"
  end

  def test_gp1_reset_restores_15bit_display_state
    @gpu.gp1(0x08_00_00_10) # 24-bit display mode
    assert @gpu.instance_variable_get(:@color_depth_24), "precondition: display should be 24-bit"

    @gpu.gp1(0x00_00_00_00)

    refute @gpu.instance_variable_get(:@color_depth_24), "reset should restore 15-bit display mode"
    assert_equal 320, @gpu.instance_variable_get(:@horizontal_res)
    assert_equal 240, @gpu.instance_variable_get(:@vertical_res)
    assert_equal 0, @gpu.status & PSX::GPU::STAT_COLOR_DEPTH
  end

  def test_gp1_reset_restores_texture_environment
    @gpu.gp0(0xE1_00_01_9F)
    @gpu.gp0(0xE2_00_7F_FF)
    @gpu.gp0(0xE6_00_00_03)

    @gpu.gp1(0x00_00_00_00)

    assert_equal 0, @gpu.instance_variable_get(:@texture_page_x)
    assert_equal 0, @gpu.instance_variable_get(:@texture_page_y)
    assert_equal 0, @gpu.instance_variable_get(:@texture_depth)
    assert_equal 0, @gpu.instance_variable_get(:@texture_window_mask_x)
    assert_equal 0, @gpu.instance_variable_get(:@texture_window_mask_y)
    refute @gpu.instance_variable_get(:@set_mask_bit)
    refute @gpu.instance_variable_get(:@check_mask_bit)
  end

  def test_framebuffer_cache_tracks_display_format
    @gpu.gp1(0x08_00_00_10) # 24-bit display mode
    @gpu.vram[0] = 0x001F
    fb24 = @gpu.framebuffer

    @gpu.gp1(0x08_00_00_00) # 15-bit display mode
    fb15 = @gpu.framebuffer

    refute_equal fb24[:rgba].byteslice(0, 4), fb15[:rgba].byteslice(0, 4)
    assert_equal 248, fb15[:rgba].getbyte(0), "15-bit cached frame should be regenerated after mode switch"
  end

  def test_textured_gouraud_triangle_modulates_with_interpolated_vertex_color
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_50_50)

    vram = @gpu.vram
    24.times do |y|
      24.times do |x|
        vram[(256 + y) * PSX::GPU::VRAM_WIDTH + x] = 0x4210
      end
    end

    # Gouraud, textured, modulated triangle. TPage selects direct-color
    # texture data at Y=256, so the CLUT word is irrelevant.
    @gpu.gp0(0x34_00_00_FF)
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_00_FF_00)
    @gpu.gp0(0x00_00_00_14)
    @gpu.gp0(0x0110_00_14)
    @gpu.gp0(0x00_FF_00_00)
    @gpu.gp0(0x00_14_00_00)
    @gpu.gp0(0x0000_14_00)

    left = vram[2 * PSX::GPU::VRAM_WIDTH + 2]
    right = vram[2 * PSX::GPU::VRAM_WIDTH + 18]

    assert (left & 0x001F) > ((left >> 5) & 0x001F), "left side should keep the red vertex tint"
    assert ((right >> 5) & 0x001F) > (right & 0x001F), "right side should pick up the green vertex tint"
  end

  def test_gouraud_triangle_applies_draw_mode_dither
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_08_08)
    @gpu.gp0(0xE1_00_02_00) # dither enabled

    @gpu.gp0(0x30_00_00_07) # shaded opaque triangle, all vertices red=7
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x00_00_00_07)
    @gpu.gp0(0x00_00_00_08)
    @gpu.gp0(0x00_00_00_07)
    @gpu.gp0(0x00_08_00_00)

    assert_equal 0x0001, @gpu.vram[3], "DuckStation's dither matrix raises red=7 at x=3,y=0"
    assert_equal 0x0000, @gpu.vram[0], "negative dither at x=0,y=0 keeps red=7 below 5-bit red 1"
  end

  def test_gouraud_line_interpolates_vertex_colors
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_04_08)

    @gpu.gp0(0x50_00_00_00) # shaded opaque line, black to red
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x00_00_00_FF)
    @gpu.gp0(0x00_00_00_08)

    assert_equal 0x0000, @gpu.vram[0]
    assert_equal 0x001F, @gpu.vram[8]
    assert_operator @gpu.vram[4] & 0x001F, :>, 0
  end

  def test_flat_line_applies_draw_mode_dither
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_04_03)
    @gpu.gp0(0xE1_00_02_00) # dither enabled

    @gpu.gp0(0x40_00_00_07) # flat opaque line, red=7
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x00_00_00_03)

    assert_equal 0x0000, @gpu.vram[0], "negative dither at x=0,y=0 keeps red=7 below 5-bit red 1"
    assert_equal 0x0001, @gpu.vram[3], "DuckStation dithers line primitives when E1 bit 9 is set"
  end

  def test_semi_transparent_line_blends_with_background
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_00_00)
    @gpu.vram[0] = 0x001F # red background

    @gpu.gp0(0x42_00_FF_00) # semi-transparent flat green line
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x00_00_00_00)

    assert_equal 0x01EF, @gpu.vram[0]
  end

  def test_modulated_textured_triangle_applies_draw_mode_dither
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_20_08)
    @gpu.gp0(0xE1_00_02_00) # dither enabled
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x001F

    @gpu.gp0(0x24_00_00_04) # modulated textured opaque triangle, red=4
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_00_00_08)
    @gpu.gp0(0x0110_00_00) # direct-color texture page at Y=256
    @gpu.gp0(0x00_08_00_00)
    @gpu.gp0(0x0000_00_00)

    assert_equal 0x0001, @gpu.vram[3], "positive dither should lift the modulated texel above zero"
    assert_equal 0x0000, @gpu.vram[0], "negative dither should keep the same modulated texel at zero"
  end

  def test_textured_draw_preserves_texel_mask_bit
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_10_10)
    @gpu.gp0(0xE1_00_01_10) # direct-color texture page at Y=256

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x8001

    @gpu.gp0(0x65_00_00_00) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_01_00_01)

    assert_equal 0x8001, @gpu.vram[0], "texture bit 15 should be copied into the framebuffer"
  end

  def test_reserved_texture_mode_samples_direct_color
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_01_01)
    @gpu.gp0(0xE1_00_01_90) # reserved texture mode at Y=256; DuckStation aliases direct color

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x001F

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_01_00_01)

    assert_equal 0x001F, @gpu.vram[0]
  end

  def test_textured_rectangle_snapshots_clut_before_drawing
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_03_01)
    @gpu.gp0(0xE1_00_00_10) # 4-bit texture page at Y=256

    @gpu.vram[1] = 0x03E0 # CLUT index 1 = green
    @gpu.vram[2] = 0x001F # CLUT index 2 = red
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x0012 # U0=index 2, U1=index 1

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_01) # draw over CLUT entry 1 first
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_01_00_02)

    assert_equal 0x001F, @gpu.vram[1]
    assert_equal 0x03E0, @gpu.vram[2], "DuckStation snapshots the CLUT before rasterizing textured primitives"
  end

  def test_odd_cpu_to_vram_upload_does_not_write_padding_halfword
    @gpu.vram[1] = 0x1234

    @gpu.gp0(0xA0_00_00_00)
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x00_01_00_01)
    @gpu.gp0(0x03E0_001F)

    assert_equal 0x001F, @gpu.vram[0]
    assert_equal 0x1234, @gpu.vram[1], "odd-sized uploads should consume but not store the padding halfword"
  end

  def test_textured_polygon_tpage_updates_following_rectangle_texture_page
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_40_40)
    @gpu.gp0(0xE1_00_00_00)

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 576] = 0x001F

    @gpu.gp0(0x25_7F_7F_7F) # raw textured triangle
    @gpu.gp0(0x00_10_00_10)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_10_00_18)
    @gpu.gp0(0x0119_00_00) # page x=576, y=256, direct-color
    @gpu.gp0(0x00_18_00_10)
    @gpu.gp0(0x0000_00_00)

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_01_00_01)

    assert_equal 576, @gpu.instance_variable_get(:@texture_page_x)
    assert_equal 256, @gpu.instance_variable_get(:@texture_page_y)
    assert_equal 2, @gpu.instance_variable_get(:@texture_depth)
    assert_equal 0x001F, @gpu.vram[0], "rectangle should use the tpage set by the preceding polygon"
  end

  def test_textured_polygon_tpage_does_not_update_draw_mode_texture_flip
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_08_02)
    @gpu.gp0(0xE1_00_01_10) # direct-color texture page at Y=256, no flip

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 8] = 0x001F
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 9] = 0x03E0
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 10] = 0x7C00

    @gpu.gp0(0x25_7F_7F_7F) # raw textured triangle
    @gpu.gp0(0x00_20_00_20)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_20_00_21)
    @gpu.gp0(0x1110_00_00) # bit 12 set in polygon texpage word; should not set x-flip
    @gpu.gp0(0x00_21_00_20)
    @gpu.gp0(0x0000_00_00)

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_08)
    @gpu.gp0(0x00_01_00_03)

    refute @gpu.instance_variable_get(:@texture_x_flip)
    assert_equal 0x001F, @gpu.vram[0], "polygon tpage bit 12 must not flip following rectangles"
    assert_equal 0x03E0, @gpu.vram[1]
    assert_equal 0x7C00, @gpu.vram[2]
  end

  def test_textured_rectangle_draw_mode_x_flip_bit_does_not_reverse_sampling
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_08_02)
    @gpu.gp0(0xE1_00_11_10) # direct-color texture page at Y=256, bit 12 set
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 8] = 0x001F
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 9] = 0x03E0
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 10] = 0x7C00

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_08)
    @gpu.gp0(0x00_01_00_03)

    assert_equal 0x001F, @gpu.vram[0], "DuckStation steps rectangle U forward even when bit 12 is set"
    assert_equal 0x03E0, @gpu.vram[1]
    assert_equal 0x7C00, @gpu.vram[2]
  end

  def test_textured_rectangle_draw_mode_y_flip_bit_does_not_reverse_sampling
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_08_02)
    @gpu.gp0(0xE1_00_21_10) # direct-color texture page at Y=256, bit 13 set
    @gpu.vram[(256 + 8) * PSX::GPU::VRAM_WIDTH] = 0x001F
    @gpu.vram[(256 + 9) * PSX::GPU::VRAM_WIDTH] = 0x03E0
    @gpu.vram[(256 + 10) * PSX::GPU::VRAM_WIDTH] = 0x7C00

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_08_00)
    @gpu.gp0(0x00_03_00_01)

    assert_equal 0x001F, @gpu.vram[0], "DuckStation steps rectangle V forward even when bit 13 is set"
    assert_equal 0x03E0, @gpu.vram[PSX::GPU::VRAM_WIDTH]
    assert_equal 0x7C00, @gpu.vram[PSX::GPU::VRAM_WIDTH * 2]
  end

  def test_rectangle_positions_are_11bit_signed
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_00_00)
    @gpu.gp0(0xE5_00_00_01) # draw offset x=1

    @gpu.gp0(0x68_00_00_FF) # 1x1 red rectangle
    @gpu.gp0(0x0000_07FF)   # x=-1 in the GPU's 11-bit vertex format

    assert_equal 0x001F, @gpu.vram[0], "11-bit x=-1 plus offset 1 should land at x=0"
  end

  def test_variable_rectangle_size_masks_to_vram_dimensions
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_04_00)

    @gpu.gp0(0x60_00_00_FF) # variable-size red rectangle
    @gpu.gp0(0x0000_0000)
    @gpu.gp0(0x0001_0401)   # width masks to 1, height masks to 1

    assert_equal 0x001F, @gpu.vram[0]
    assert_equal 0, @gpu.vram[1], "high width bits must not stretch the rectangle"
  end

  def test_vram_copy_uses_reverse_order_for_overlapping_rows
    @gpu.vram[0] = 0x001F
    @gpu.vram[1] = 0x03E0
    @gpu.vram[2] = 0x7C00

    @gpu.gp0(0x80_00_00_00)
    @gpu.gp0(0x0000_0000) # src x=0, y=0
    @gpu.gp0(0x0000_0001) # dst x=1, y=0
    @gpu.gp0(0x0001_0003) # width=3, height=1

    assert_equal 0x001F, @gpu.vram[1]
    assert_equal 0x03E0, @gpu.vram[2]
    assert_equal 0x7C00, @gpu.vram[3], "overlapping copies should read the original source pixels"
  end

  def test_vram_copy_honors_mask_bits
    @gpu.vram[0] = 0x001F
    @gpu.vram[1] = 0x03E0
    @gpu.vram[10] = 0x8001
    @gpu.vram[11] = 0x0002
    @gpu.gp0(0xE6_00_00_03) # set mask bit and skip masked destination pixels

    @gpu.gp0(0x80_00_00_00)
    @gpu.gp0(0x0000_0000)
    @gpu.gp0(0x0000_000A)
    @gpu.gp0(0x0001_0002)

    assert_equal 0x8001, @gpu.vram[10], "masked destination pixel should be preserved"
    assert_equal 0x83E0, @gpu.vram[11], "copied pixels should receive the draw mask bit"
  end

  def test_8bit_clut_lookup_wraps_at_vram_row_end
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_01_01)
    @gpu.gp0(0xE1_00_00_90) # 8-bit texture page at Y=256

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x0014 # first texture byte: palette index 20
    @gpu.vram[4] = 0x001F
    @gpu.vram[PSX::GPU::VRAM_WIDTH + 4] = 0x03E0

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x003F_00_00) # CLUT starts at x=1008; index 20 wraps to x=4
    @gpu.gp0(0x00_01_00_01)

    assert_equal 0x001F, @gpu.vram[0], "8-bit CLUT lookup should wrap within the palette row"
  end

  def test_textured_rectangle_applies_texture_window_before_8bit_lookup
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_01_01)
    @gpu.gp0(0xE1_00_00_90) # 8-bit texture page at Y=256
    @gpu.gp0(0xE2_00_04_01) # mask_x=1, offset_x=1 => U 0 maps to U 8

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x0001
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 4] = 0x0002
    @gpu.vram[1] = 0x001F
    @gpu.vram[2] = 0x03E0

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_01_00_01)

    assert_equal 0x03E0, @gpu.vram[0], "texture window must remap U before selecting the 8-bit texel byte"
  end

  def test_textured_rectangle_applies_texture_window_before_4bit_lookup
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_01_01)
    @gpu.gp0(0xE1_00_00_10) # 4-bit texture page at Y=256
    @gpu.gp0(0xE2_00_04_01) # mask_x=1, offset_x=1 => U 0 maps to U 8

    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH] = 0x0001
    @gpu.vram[256 * PSX::GPU::VRAM_WIDTH + 2] = 0x0002
    @gpu.vram[1] = 0x001F
    @gpu.vram[2] = 0x03E0

    @gpu.gp0(0x65_7F_7F_7F) # raw textured variable rectangle
    @gpu.gp0(0x00_00_00_00)
    @gpu.gp0(0x0000_00_00)
    @gpu.gp0(0x00_01_00_01)

    assert_equal 0x03E0, @gpu.vram[0], "texture window must remap U before selecting the 4-bit texel nibble"
  end

  def test_gp1_info_reads_internal_gpu_registers
    @gpu.gp0(0xE2_00_8C_43)
    @gpu.gp0(0xE3_00_10_20)
    @gpu.gp0(0xE4_00_28_40)
    @gpu.gp0(0xE5_3F_7F_FF)

    @gpu.gp1(0x10_00_00_02)
    assert_equal 0x08C43, @gpu.read_data

    @gpu.gp1(0x10_00_00_03)
    assert_equal 0x01020, @gpu.read_data

    @gpu.gp1(0x10_00_00_04)
    assert_equal 0x02840, @gpu.read_data

    @gpu.gp1(0x10_00_00_05)
    assert_equal 0x3F7FFF, @gpu.read_data
  end
end
