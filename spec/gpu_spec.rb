# frozen_string_literal: true

require_relative "spec_helper"

class GPUSpec < Minitest::Test
  include TestHelpers

  def setup
    @gpu = create_gpu
  end

  # === Status Register Tests ===

  def test_initial_status_has_ready_bits_set
    status = @gpu.status
    assert status & PSX::GPU::STAT_CMD_READY != 0, "CMD_READY should be set"
    assert status & PSX::GPU::STAT_DMA_READY != 0, "DMA_READY should be set"
    assert status & PSX::GPU::STAT_VRAM_TO_CPU_READY != 0, "VRAM_TO_CPU_READY should be set"
  end

  def test_vblank_toggles_odd_field
    initial_status = @gpu.status
    initial_odd = (initial_status & PSX::GPU::STAT_DRAWING_ODD) != 0

    @gpu.vblank
    after_first = (@gpu.status & PSX::GPU::STAT_DRAWING_ODD) != 0

    @gpu.vblank
    after_second = (@gpu.status & PSX::GPU::STAT_DRAWING_ODD) != 0

    refute_equal initial_odd, after_first, "First vblank should toggle odd field"
    assert_equal initial_odd, after_second, "Second vblank should restore odd field"
  end

  # === GP1 Command Tests ===

  def test_gp1_reset_clears_state
    # Set some state first
    @gpu.gp1(0x05_00_10_20)  # Set display start
    @gpu.gp1(0x00_00_00_00)  # Reset

    status = @gpu.status
    assert status & PSX::GPU::STAT_DISPLAY_ENABLE != 0, "Display should be disabled after reset"
  end

  def test_gp1_display_enable
    @gpu.gp1(0x03_00_00_00)  # Enable display
    status = @gpu.status
    assert (status & PSX::GPU::STAT_DISPLAY_ENABLE) == 0, "Display enable bit should be 0 when enabled"

    @gpu.gp1(0x03_00_00_01)  # Disable display
    status = @gpu.status
    assert (status & PSX::GPU::STAT_DISPLAY_ENABLE) != 0, "Display enable bit should be 1 when disabled"
  end

  def test_gp1_dma_direction
    @gpu.gp1(0x04_00_00_02)  # Set DMA direction to 2
    status = @gpu.status
    direction = (status >> 29) & 0x3
    assert_equal 2, direction
  end

  # === GP0 Environment Commands ===

  def test_gp0_draw_area_top_left
    # E3 format: bits 0-9 = X, bits 10-18 = Y
    # (64, 4) = 64 | (4 << 10) = 64 | 0x1000 = 0x1040
    @gpu.gp0(0xE300_1040)

    left = @gpu.instance_variable_get(:@draw_area_left)
    top = @gpu.instance_variable_get(:@draw_area_top)

    assert_equal 64, left
    assert_equal 4, top
  end

  def test_gp0_draw_area_bottom_right
    # E4 format: bits 0-9 = X, bits 10-18 = Y
    # (128, 8) = 128 | (8 << 10) = 0x80 | 0x2000 = 0x2080
    @gpu.gp0(0xE400_2080)

    right = @gpu.instance_variable_get(:@draw_area_right)
    bottom = @gpu.instance_variable_get(:@draw_area_bottom)

    assert_equal 128, right
    assert_equal 8, bottom
  end

  def test_gp0_draw_offset
    @gpu.gp0(0xE5_00_08_10)  # Set draw offset

    offset_x = @gpu.instance_variable_get(:@draw_offset_x)
    offset_y = @gpu.instance_variable_get(:@draw_offset_y)

    assert_equal 16, offset_x
    assert_equal 1, offset_y
  end

  # === Polygon Rendering Tests ===

  def test_monochrome_triangle_draws_pixels
    # Set up draw area
    @gpu.gp0(0xE3_00_00_00)  # Top-left (0, 0)
    @gpu.gp0(0xE4_00_C0_FF)  # Bottom-right (255, 3)

    # Draw white triangle: command + 3 vertices
    @gpu.gp0(0x20_FF_FF_FF)  # Monochrome triangle, white
    @gpu.gp0(0x00_00_00_32)  # Vertex 0: (50, 0)
    @gpu.gp0(0x00_14_00_00)  # Vertex 1: (0, 20)
    @gpu.gp0(0x00_14_00_64)  # Vertex 2: (100, 20)

    # Check that some pixels were drawn
    vram = @gpu.vram
    non_zero = vram.count { |p| p != 0 }
    assert non_zero > 0, "Triangle should have drawn some pixels"
  end

  def test_monochrome_quad_draws_pixels
    # Set up draw area
    @gpu.gp0(0xE3_00_00_00)
    @gpu.gp0(0xE4_00_C0_FF)

    # Draw red quad
    @gpu.gp0(0x28_00_00_FF)  # Monochrome quad, red
    @gpu.gp0(0x00_00_00_00)  # (0, 0)
    @gpu.gp0(0x00_00_00_0A)  # (10, 0)
    @gpu.gp0(0x00_0A_00_00)  # (0, 10)
    @gpu.gp0(0x00_0A_00_0A)  # (10, 10)

    vram = @gpu.vram
    non_zero = vram.count { |p| p != 0 }
    assert non_zero > 50, "Quad should have drawn many pixels"
  end

  # === VRAM Transfer Tests ===

  def test_cpu_to_vram_transfer_size_calculation
    # This tests the operator precedence fix
    # Size 0x0030003C should give 60x48, not 0x0

    @gpu.gp0(0xA0_00_00_00)  # CPU to VRAM command
    @gpu.gp0(0x00_00_00_00)  # Position (0, 0)
    @gpu.gp0(0x00_30_00_3C)  # Size: width=60, height=48

    width = @gpu.instance_variable_get(:@vram_transfer_width)
    height = @gpu.instance_variable_get(:@vram_transfer_height)
    count = @gpu.instance_variable_get(:@vram_transfer_count)

    assert_equal 60, width, "Width should be 60"
    assert_equal 48, height, "Height should be 48"
    assert_equal (60 * 48 + 1) / 2, count, "Transfer count should be half of pixel count (rounded)"
  end

  def test_cpu_to_vram_transfer_completes
    @gpu.gp0(0xA0_00_00_00)  # CPU to VRAM
    @gpu.gp0(0x00_00_00_00)  # Position (0, 0)
    @gpu.gp0(0x00_01_00_04)  # Size: 4x1 = 4 pixels = 2 words

    mode = @gpu.instance_variable_get(:@vram_transfer_mode)
    assert_equal :cpu_to_vram, mode

    # Send 2 words of data
    @gpu.gp0(0x7FFF_7FFF)  # Two white pixels
    @gpu.gp0(0x7FFF_7FFF)  # Two more white pixels

    mode_after = @gpu.instance_variable_get(:@vram_transfer_mode)
    assert_nil mode_after, "Transfer mode should be nil after completion"

    # Check VRAM
    vram = @gpu.vram
    assert_equal 0x7FFF, vram[0], "First pixel should be white"
    assert_equal 0x7FFF, vram[1], "Second pixel should be white"
  end

  # === Framebuffer Output Tests ===

  def test_framebuffer_returns_correct_dimensions
    fb = @gpu.framebuffer
    assert_equal 320, fb[:width]
    assert_equal 240, fb[:height]
    # RGBA format: 4 bytes per pixel
    assert_equal 320 * 240 * 4, fb[:rgba].bytesize
  end

  def test_framebuffer_converts_colors_correctly
    # Write a known color to VRAM at display position
    # RGB555: R=31, G=0, B=0 = 0x001F (red)
    @gpu.vram[0] = 0x001F

    fb = @gpu.framebuffer
    # RGBA format: R should be 31<<3 = 248, A should be 255
    assert_equal 248, fb[:rgba].getbyte(0), "Red channel should be ~248"
    assert_equal 0, fb[:rgba].getbyte(1), "Green channel should be 0"
    assert_equal 0, fb[:rgba].getbyte(2), "Blue channel should be 0"
    assert_equal 255, fb[:rgba].getbyte(3), "Alpha channel should be 255"
  end

  def test_framebuffer_reads_24bit_display_pixels
    @gpu.gp1(0x08_00_00_10) # 24-bit display mode
    @gpu.vram[0] = 0x2211
    @gpu.vram[1] = 0x4433
    @gpu.vram[2] = 0x6655

    fb = @gpu.framebuffer

    assert_equal 0x33, fb[:rgba].getbyte(0), "First pixel red should come from byte 2"
    assert_equal 0x22, fb[:rgba].getbyte(1), "First pixel green should come from byte 1"
    assert_equal 0x11, fb[:rgba].getbyte(2), "First pixel blue should come from byte 0"
    assert_equal 0x66, fb[:rgba].getbyte(4), "Second pixel red should come from byte 5"
    assert_equal 0x55, fb[:rgba].getbyte(5), "Second pixel green should come from byte 4"
    assert_equal 0x44, fb[:rgba].getbyte(6), "Second pixel blue should come from byte 3"
  end
end
