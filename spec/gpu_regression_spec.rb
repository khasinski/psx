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
