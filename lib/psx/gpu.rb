# frozen_string_literal: true

module PSX
  # Graphics Processing Unit
  # Handles 2D/3D rendering to VRAM
  class GPU
    # VRAM dimensions
    VRAM_WIDTH  = 1024
    VRAM_HEIGHT = 512

    # Status register bits
    STAT_TEXTURE_PAGE_X   = 0x0000_000F  # Texture page X base (N*64)
    STAT_TEXTURE_PAGE_Y   = 0x0000_0010  # Texture page Y base (N*256)
    STAT_SEMI_TRANSPARENCY = 0x0000_0060 # Semi-transparency mode
    STAT_TEXTURE_DEPTH    = 0x0000_0180  # Texture color depth
    STAT_DITHER           = 0x0000_0200  # Dither enabled
    STAT_DRAW_TO_DISPLAY  = 0x0000_0400  # Drawing to display area allowed
    STAT_SET_MASK_BIT     = 0x0000_0800  # Set mask bit when drawing
    STAT_DRAW_PIXELS      = 0x0000_1000  # Draw pixels (0=always, 1=not to masked)
    STAT_INTERLACE_FIELD  = 0x0000_2000  # Interlace field
    STAT_REVERSE_FLAG     = 0x0000_4000  # Reverse flag
    STAT_TEXTURE_DISABLE  = 0x0000_8000  # Texture disable
    STAT_HORIZONTAL_RES2  = 0x0001_0000  # Horizontal resolution 2
    STAT_HORIZONTAL_RES1  = 0x0006_0000  # Horizontal resolution 1
    STAT_VERTICAL_RES     = 0x0008_0000  # Vertical resolution (0=240, 1=480)
    STAT_VIDEO_MODE       = 0x0010_0000  # Video mode (0=NTSC, 1=PAL)
    STAT_COLOR_DEPTH      = 0x0020_0000  # Display color depth (0=15bit, 1=24bit)
    STAT_VERTICAL_INTERLACE = 0x0040_0000 # Vertical interlace
    STAT_DISPLAY_ENABLE   = 0x0080_0000  # Display enable (0=enabled, 1=disabled)
    STAT_IRQ              = 0x0100_0000  # IRQ flag
    STAT_DMA_REQUEST      = 0x0200_0000  # DMA request
    STAT_CMD_READY        = 0x0400_0000  # Ready for command
    STAT_VRAM_TO_CPU_READY = 0x0800_0000 # Ready for VRAM to CPU transfer
    STAT_DMA_READY        = 0x1000_0000  # Ready for DMA
    STAT_DMA_DIRECTION    = 0x6000_0000  # DMA direction
    STAT_DRAWING_ODD      = 0x8000_0000  # Drawing odd lines (interlace)

    # GP0 command types
    CMD_NOP           = 0x00
    CMD_CLEAR_CACHE   = 0x01
    CMD_FILL_RECT     = 0x02
    CMD_POLY_BASE     = 0x20  # 0x20-0x3F polygons
    CMD_LINE_BASE     = 0x40  # 0x40-0x5F lines
    CMD_RECT_BASE     = 0x60  # 0x60-0x7F rectangles
    CMD_COPY_VRAM_VRAM = 0x80
    CMD_COPY_CPU_VRAM = 0xA0
    CMD_COPY_VRAM_CPU = 0xC0
    CMD_ENV_BASE      = 0xE0  # 0xE0-0xEF environment commands

    attr_reader :vram

    def initialize(interrupts: nil)
      @interrupts = interrupts

      # VRAM: 1024x512 16-bit pixels
      @vram = Array.new(VRAM_WIDTH * VRAM_HEIGHT, 0)

      # Status register
      @status = STAT_CMD_READY | STAT_DMA_READY | STAT_VRAM_TO_CPU_READY

      # Display settings
      @display_enabled = false
      @display_start_x = 0
      @display_start_y = 0
      @display_h_start = 0x200
      @display_h_end = 0xC00
      @display_v_start = 0x10
      @display_v_end = 0x100
      @video_mode = :ntsc
      @horizontal_res = 320
      @vertical_res = 240
      @color_depth_24 = false
      @interlaced = false

      # Drawing area
      @draw_area_left = 0
      @draw_area_top = 0
      @draw_area_right = 0
      @draw_area_bottom = 0
      @draw_offset_x = 0
      @draw_offset_y = 0

      # Texture settings
      @texture_page_x = 0
      @texture_page_y = 0
      @texture_depth = 0  # 0=4bit, 1=8bit, 2=15bit
      @semi_transparency = 0
      @texture_window_mask_x = 0
      @texture_window_mask_y = 0
      @texture_window_offset_x = 0
      @texture_window_offset_y = 0
      @texture_disable_allow = false

      # Mask settings
      @set_mask_bit = false
      @check_mask_bit = false

      # Command buffer for multi-word commands
      @cmd_buffer = []
      @cmd_remaining = 0
      @current_cmd = 0

      # VRAM transfer state
      @vram_transfer_x = 0
      @vram_transfer_y = 0
      @vram_transfer_start_x = 0  # Starting X for line wrap detection
      @vram_transfer_width = 0
      @vram_transfer_height = 0
      @vram_transfer_count = 0
      @vram_transfer_mode = nil  # :cpu_to_vram or :vram_to_cpu
      @vram_read_buffer = []

      # Framebuffer caching
      @framebuffer_dirty = true
      @framebuffer_cache = nil

      # DMA direction
      @dma_direction = 0

      # Interlace field (toggled by VBlank)
      @odd_field = false
    end

    # Called by emulator on VBlank to toggle interlace field
    def vblank
      @odd_field = !@odd_field
    end

    def status
      stat = @status

      # Update dynamic bits
      stat &= ~STAT_DISPLAY_ENABLE
      stat |= STAT_DISPLAY_ENABLE unless @display_enabled

      stat &= ~STAT_DMA_DIRECTION
      stat |= (@dma_direction << 29) & STAT_DMA_DIRECTION

      # Bit 31: Drawing odd lines in interlace mode
      stat &= ~STAT_DRAWING_ODD
      stat |= STAT_DRAWING_ODD if @odd_field

      stat
    end

    def read_data
      if @vram_transfer_mode == :vram_to_cpu && !@vram_read_buffer.empty?
        @vram_read_buffer.shift
      else
        0
      end
    end

    # GP0 - Rendering commands and VRAM access
    def gp0(value)
      if @vram_transfer_mode == :cpu_to_vram
        vram_write_data(value)
        return
      end

      if @cmd_remaining > 0
        @cmd_buffer << value
        @cmd_remaining -= 1

        if @cmd_remaining == 0
          execute_gp0_command
        end
        return
      end

      cmd = (value >> 24) & 0xFF
      @current_cmd = cmd
      @cmd_buffer = [value]

      case cmd
      when CMD_NOP
        # Do nothing
      when CMD_CLEAR_CACHE
        # Clear texture cache - ignore for now
      when CMD_FILL_RECT
        @cmd_remaining = 2
      when 0x20..0x3F
        # Polygons
        @cmd_remaining = polygon_word_count(cmd) - 1
      when 0x40..0x5F
        # Lines
        @cmd_remaining = line_word_count(cmd) - 1
      when 0x60..0x7F
        # Rectangles
        @cmd_remaining = rectangle_word_count(cmd) - 1
      when CMD_COPY_VRAM_VRAM
        @cmd_remaining = 3
      when CMD_COPY_CPU_VRAM
        @cmd_remaining = 2
      when CMD_COPY_VRAM_CPU
        @cmd_remaining = 2
      when 0xE1
        gp0_draw_mode(value)
      when 0xE2
        gp0_texture_window(value)
      when 0xE3
        gp0_draw_area_top_left(value)
      when 0xE4
        gp0_draw_area_bottom_right(value)
      when 0xE5
        gp0_draw_offset(value)
      when 0xE6
        gp0_mask_settings(value)
      else
        # Unknown command - ignore
      end

      execute_gp0_command if @cmd_remaining == 0 && @cmd_buffer.length > 0
    end

    # GP1 - Display control
    def gp1(value)
      cmd = (value >> 24) & 0xFF

      case cmd
      when 0x00
        gp1_reset
      when 0x01
        gp1_reset_command_buffer
      when 0x02
        gp1_acknowledge_irq
      when 0x03
        gp1_display_enable(value)
      when 0x04
        gp1_dma_direction(value)
      when 0x05
        gp1_display_start(value)
      when 0x06
        gp1_horizontal_range(value)
      when 0x07
        gp1_vertical_range(value)
      when 0x08
        gp1_display_mode(value)
      when 0x09
        gp1_texture_disable(value)
      when 0x10..0x1F
        gp1_gpu_info(value)
      end
    end

    def gp1_texture_disable(value)
      @texture_disable_allow = (value & 1) != 0
    end

    # Get current framebuffer as RGBA packed binary string for display
    # Returns hash with :width, :height, :rgba (binary string)
    # Uses caching to avoid regenerating unchanged frames
    def framebuffer
      # Return cached framebuffer if VRAM hasn't changed
      if !@framebuffer_dirty && @framebuffer_cache &&
         @framebuffer_cache[:width] == @horizontal_res &&
         @framebuffer_cache[:height] == @vertical_res
        return @framebuffer_cache
      end

      width = @horizontal_res
      height = @vertical_res
      num_pixels = width * height

      # Build RGBA array and pack once (faster than building string)
      rgba_arr = Array.new(num_pixels * 4)
      dst_i = 0

      height.times do |y|
        vram_row = (@display_start_y + y) * VRAM_WIDTH + @display_start_x
        width.times do |x|
          color16 = @vram[vram_row + x] || 0

          # Convert 15-bit to 24-bit RGB
          rgba_arr[dst_i] = (color16 & 0x001F) << 3      # R
          rgba_arr[dst_i + 1] = (color16 & 0x03E0) >> 2  # G
          rgba_arr[dst_i + 2] = (color16 & 0x7C00) >> 7  # B
          rgba_arr[dst_i + 3] = 255                       # A
          dst_i += 4
        end
      end

      @framebuffer_dirty = false
      @framebuffer_cache = { width: width, height: height, rgba: rgba_arr.pack("C*") }
    end

    # Mark framebuffer as needing regeneration (call when VRAM is modified)
    def mark_dirty
      @framebuffer_dirty = true
    end

    private

    # GP0 command execution
    def execute_gp0_command
      case @current_cmd
      when CMD_FILL_RECT
        mark_dirty
        gp0_fill_rect
      when 0x20..0x3F
        mark_dirty
        gp0_polygon
      when 0x40..0x5F
        mark_dirty
        gp0_line
      when 0x60..0x7F
        mark_dirty
        gp0_rectangle
      when CMD_COPY_VRAM_VRAM
        mark_dirty
        gp0_copy_vram_vram
      when CMD_COPY_CPU_VRAM
        mark_dirty
        gp0_copy_cpu_vram
      when CMD_COPY_VRAM_CPU
        gp0_copy_vram_cpu  # Reading from VRAM doesn't modify it
      end

      @cmd_buffer = []
      @current_cmd = 0
    end

    # Word counts for multi-word commands
    def polygon_word_count(cmd)
      # Bit 0: Gouraud (adds colors for each vertex)
      # Bit 2: Textured (adds UV + clut for each vertex)
      # Bit 3: Quad (4 vertices instead of 3)
      gouraud = (cmd & 0x10) != 0
      textured = (cmd & 0x04) != 0
      quad = (cmd & 0x08) != 0

      vertices = quad ? 4 : 3
      words = 1  # Command + color

      if textured
        # Each vertex has position + texcoord
        words += vertices * 2
        words += 1 if gouraud  # Extra colors if gouraud
        words += (vertices - 1) if gouraud  # Colors for other vertices
      else
        words += vertices  # Just positions
        words += (vertices - 1) if gouraud  # Colors for other vertices
      end

      words
    end

    def line_word_count(cmd)
      # Bit 3: Polyline
      # Bit 4: Gouraud
      gouraud = (cmd & 0x10) != 0
      polyline = (cmd & 0x08) != 0

      if polyline
        # Polyline - variable length, terminated by 0x5555_5555 or 0x5000_5000
        # For now, just handle 2-point lines
        gouraud ? 4 : 3
      else
        gouraud ? 4 : 3
      end
    end

    def rectangle_word_count(cmd)
      # Bits 3-4: Size (0=variable, 1=1x1, 2=8x8, 3=16x16)
      # Bit 2: Textured
      size = (cmd >> 3) & 0x3
      textured = (cmd & 0x04) != 0

      words = 2  # Command+color, position
      words += 1 if textured  # Texcoord
      words += 1 if size == 0  # Variable size needs dimensions

      words
    end

    # GP0 Drawing commands
    def gp0_fill_rect
      color = @cmd_buffer[0] & 0x00FF_FFFF
      pos = @cmd_buffer[1]
      size = @cmd_buffer[2]

      x = pos & 0x3F0  # Aligned to 16 pixels
      y = (pos >> 16) & 0x1FF
      w = ((size & 0x3FF) + 0xF) & ~0xF  # Round up to 16
      h = (size >> 16) & 0x1FF

      r = color & 0xFF
      g = (color >> 8) & 0xFF
      b = (color >> 16) & 0xFF
      pixel = rgb_to_vram(r, g, b)

      h.times do |dy|
        w.times do |dx|
          vx = (x + dx) % VRAM_WIDTH
          vy = (y + dy) % VRAM_HEIGHT
          @vram[vy * VRAM_WIDTH + vx] = pixel
        end
      end
    end

    def gp0_polygon
      cmd = @current_cmd
      gouraud = (cmd & 0x10) != 0
      textured = (cmd & 0x04) != 0
      quad = (cmd & 0x08) != 0
      semi_transparent = (cmd & 0x02) != 0
      raw_texture = (cmd & 0x01) != 0

      vertices = quad ? 4 : 3

      # Parse vertices
      points = []
      colors = []
      texcoords = []

      idx = 0
      vertices.times do |v|
        # First word always has color (or just first vertex if not gouraud)
        if v == 0 || gouraud
          c = @cmd_buffer[idx]
          colors << { r: c & 0xFF, g: (c >> 8) & 0xFF, b: (c >> 16) & 0xFF }
          idx += 1
        else
          colors << colors[0]
        end

        # Position
        pos = @cmd_buffer[idx]
        x = (pos & 0xFFFF)
        x = x - 0x10000 if x >= 0x8000  # Sign extend
        y = (pos >> 16) & 0xFFFF
        y = y - 0x10000 if y >= 0x8000
        points << { x: x + @draw_offset_x, y: y + @draw_offset_y }
        idx += 1

        # Texcoord
        if textured
          tc = @cmd_buffer[idx]
          texcoords << { u: tc & 0xFF, v: (tc >> 8) & 0xFF, clut: (tc >> 16) & 0xFFFF }
          idx += 1
        end
      end

      # Draw triangles
      if textured
        # Get CLUT from first texcoord (bits 16-31)
        clut = texcoords[0][:clut]

        # Get texture page from second texcoord (bits 16-31)
        # This overrides the global texture page settings for this primitive
        tpage = texcoords[1][:clut]  # Reusing :clut field, it's actually tpage for vertex 1
        tex_page_x = (tpage & 0x0F) * 64
        tex_page_y = ((tpage >> 4) & 0x01) * 256
        tex_depth = (tpage >> 7) & 0x03

        # A textured polygon's tpage parameter also rewrites GPUSTAT bits 0-8
        # (and, when GP1 09 allowed it, bit 15 from tpage bit 11). Bits 9-10
        # remain whatever GP0 E1 set them to (verified by ps1-tests gpu/gp0-e1).
        @status = (@status & ~0x01FF) | (tpage & 0x01FF)
        tex_disable = (@texture_disable_allow && (tpage & (1 << 11)) != 0) ? 0x8000 : 0
        @status = (@status & ~0x8000) | tex_disable

        if quad
          draw_textured_triangle(points[0], points[1], points[2],
                                 texcoords[0], texcoords[1], texcoords[2],
                                 colors[0], clut, tex_page_x, tex_page_y, tex_depth, raw_texture)
          draw_textured_triangle(points[1], points[2], points[3],
                                 texcoords[1], texcoords[2], texcoords[3],
                                 colors[1], clut, tex_page_x, tex_page_y, tex_depth, raw_texture)
        else
          draw_textured_triangle(points[0], points[1], points[2],
                                 texcoords[0], texcoords[1], texcoords[2],
                                 colors[0], clut, tex_page_x, tex_page_y, tex_depth, raw_texture)
        end
      else
        if quad
          draw_triangle(points[0], points[1], points[2], colors[0], colors[1], colors[2], gouraud)
          draw_triangle(points[1], points[2], points[3], colors[1], colors[2], colors[3], gouraud)
        else
          draw_triangle(points[0], points[1], points[2], colors[0], colors[1], colors[2], gouraud)
        end
      end
    end

    def gp0_line
      cmd = @current_cmd
      gouraud = (cmd & 0x10) != 0

      c0 = @cmd_buffer[0]
      color0 = { r: c0 & 0xFF, g: (c0 >> 8) & 0xFF, b: (c0 >> 16) & 0xFF }

      pos0 = @cmd_buffer[1]
      x0 = (pos0 & 0xFFFF)
      x0 = x0 - 0x10000 if x0 >= 0x8000
      y0 = (pos0 >> 16) & 0xFFFF
      y0 = y0 - 0x10000 if y0 >= 0x8000

      if gouraud
        c1 = @cmd_buffer[2]
        color1 = { r: c1 & 0xFF, g: (c1 >> 8) & 0xFF, b: (c1 >> 16) & 0xFF }
        pos1 = @cmd_buffer[3]
      else
        color1 = color0
        pos1 = @cmd_buffer[2]
      end

      x1 = (pos1 & 0xFFFF)
      x1 = x1 - 0x10000 if x1 >= 0x8000
      y1 = (pos1 >> 16) & 0xFFFF
      y1 = y1 - 0x10000 if y1 >= 0x8000

      draw_line(
        x0 + @draw_offset_x, y0 + @draw_offset_y,
        x1 + @draw_offset_x, y1 + @draw_offset_y,
        color0, color1, gouraud
      )
    end

    def gp0_rectangle
      cmd = @current_cmd
      textured = (cmd & 0x04) != 0
      raw_texture = (cmd & 0x01) != 0
      size_mode = (cmd >> 3) & 0x3

      c = @cmd_buffer[0]
      color = { r: c & 0xFF, g: (c >> 8) & 0xFF, b: (c >> 16) & 0xFF }

      pos = @cmd_buffer[1]
      x = (pos & 0xFFFF)
      x = x - 0x10000 if x >= 0x8000
      y = (pos >> 16) & 0xFFFF
      y = y - 0x10000 if y >= 0x8000
      x += @draw_offset_x
      y += @draw_offset_y

      idx = 2
      tex_u = 0
      tex_v = 0
      clut_x = 0
      clut_y = 0

      if textured
        tc = @cmd_buffer[idx]
        tex_u = tc & 0xFF
        tex_v = (tc >> 8) & 0xFF
        clut = (tc >> 16) & 0xFFFF
        clut_x = (clut & 0x3F) * 16
        clut_y = (clut >> 6) & 0x1FF
        idx += 1
      end

      case size_mode
      when 0  # Variable
        dims = @cmd_buffer[idx]
        w = dims & 0xFFFF
        h = (dims >> 16) & 0xFFFF
      when 1  # 1x1
        w = 1
        h = 1
      when 2  # 8x8
        w = 8
        h = 8
      when 3  # 16x16
        w = 16
        h = 16
      end

      if textured
        draw_textured_rect(x, y, w, h, tex_u, tex_v, clut_x, clut_y, color, raw_texture)
      else
        draw_rect(x, y, w, h, color)
      end
    end

    def gp0_copy_vram_vram
      src = @cmd_buffer[1]
      dst = @cmd_buffer[2]
      size = @cmd_buffer[3]

      src_x = src & 0x3FF
      src_y = (src >> 16) & 0x1FF
      dst_x = dst & 0x3FF
      dst_y = (dst >> 16) & 0x1FF
      w = (((size & 0x3FF) - 1) & 0x3FF) + 1
      h = ((((size >> 16) & 0x1FF) - 1) & 0x1FF) + 1

      h.times do |dy|
        w.times do |dx|
          sx = (src_x + dx) % VRAM_WIDTH
          sy = (src_y + dy) % VRAM_HEIGHT
          dx2 = (dst_x + dx) % VRAM_WIDTH
          dy2 = (dst_y + dy) % VRAM_HEIGHT
          @vram[dy2 * VRAM_WIDTH + dx2] = @vram[sy * VRAM_WIDTH + sx]
        end
      end
    end

    def gp0_copy_cpu_vram
      pos = @cmd_buffer[1]
      size = @cmd_buffer[2]

      @vram_transfer_x = pos & 0x3FF
      @vram_transfer_y = (pos >> 16) & 0x1FF
      @vram_transfer_start_x = @vram_transfer_x  # Remember starting X for line wrap
      w = (((size & 0xFFFF) - 1) & 0x3FF) + 1
      h = ((((size >> 16) & 0xFFFF) - 1) & 0x1FF) + 1
      @vram_transfer_width = w
      @vram_transfer_height = h
      @vram_transfer_count = ((w * h + 1) & ~1) / 2  # Words to transfer
      @vram_transfer_mode = :cpu_to_vram

      @status &= ~STAT_CMD_READY
    end

    def gp0_copy_vram_cpu
      pos = @cmd_buffer[1]
      size = @cmd_buffer[2]

      x = pos & 0x3FF
      y = (pos >> 16) & 0x1FF
      w = (((size & 0xFFFF) - 1) & 0x3FF) + 1
      h = ((((size >> 16) & 0xFFFF) - 1) & 0x1FF) + 1

      # Read VRAM into buffer
      @vram_read_buffer = []
      h.times do |dy|
        row_start = ((y + dy) % VRAM_HEIGHT) * VRAM_WIDTH
        x_pos = x
        (w / 2.0).ceil.times do
          p0 = @vram[row_start + (x_pos % VRAM_WIDTH)]
          x_pos += 1
          p1 = @vram[row_start + (x_pos % VRAM_WIDTH)]
          x_pos += 1
          @vram_read_buffer << ((p1 << 16) | p0)
        end
      end

      @vram_transfer_mode = :vram_to_cpu
      @status |= STAT_VRAM_TO_CPU_READY
    end

    def vram_write_data(value)
      return if @vram_transfer_count <= 0

      vram_write_pixel(value & 0xFFFF)
      vram_write_pixel((value >> 16) & 0xFFFF)

      @vram_transfer_count -= 1

      if @vram_transfer_count <= 0
        @vram_transfer_mode = nil
        @status |= STAT_CMD_READY
      end
    end

    def vram_write_pixel(pixel)
      idx = @vram_transfer_y * VRAM_WIDTH + (@vram_transfer_x % VRAM_WIDTH)

      # Mask bit settings apply to CPU-to-VRAM blits (verified by
      # ps1-tests gpu/mask-bit).
      unless @check_mask_bit && (@vram[idx] & 0x8000) != 0
        @vram[idx] = pixel | (@set_mask_bit ? 0x8000 : 0)
      end

      @vram_transfer_x += 1
      if @vram_transfer_x >= @vram_transfer_start_x + @vram_transfer_width
        @vram_transfer_x = @vram_transfer_start_x
        @vram_transfer_y = (@vram_transfer_y + 1) % VRAM_HEIGHT
      end
    end

    # GP0 Environment commands
    def gp0_draw_mode(value)
      @texture_page_x = (value & 0x0F) * 64
      @texture_page_y = ((value >> 4) & 0x01) * 256
      @semi_transparency = (value >> 5) & 0x03
      @texture_depth = (value >> 7) & 0x03

      @status = (@status & ~0x07FF) | (value & 0x07FF)

      # GPUSTAT bit 15 (Texture Disable) comes from E1 bit 11, but only when
      # GP1 09 ("Allow Texture Disable") has been set. With allow=false an E1
      # write force-clears bit 15 (verified by ps1-tests gpu/gp0-e1).
      bit15 = (@texture_disable_allow && (value & (1 << 11)) != 0) ? 0x8000 : 0
      @status = (@status & ~0x8000) | bit15
    end

    def gp0_texture_window(value)
      # Store raw values (in 8-texel units), don't pre-multiply
      @texture_window_mask_x = value & 0x1F
      @texture_window_mask_y = (value >> 5) & 0x1F
      @texture_window_offset_x = (value >> 10) & 0x1F
      @texture_window_offset_y = (value >> 15) & 0x1F
    end

    def gp0_draw_area_top_left(value)
      @draw_area_left = value & 0x3FF
      @draw_area_top = (value >> 10) & 0x1FF
    end

    def gp0_draw_area_bottom_right(value)
      @draw_area_right = value & 0x3FF
      @draw_area_bottom = (value >> 10) & 0x1FF
    end

    def gp0_draw_offset(value)
      x = value & 0x7FF
      y = (value >> 11) & 0x7FF
      @draw_offset_x = x >= 0x400 ? x - 0x800 : x
      @draw_offset_y = y >= 0x400 ? y - 0x800 : y
    end

    def gp0_mask_settings(value)
      @set_mask_bit = (value & 0x01) != 0
      @check_mask_bit = (value & 0x02) != 0

      @status = (@status & ~0x1800) | ((value & 0x03) << 11)
    end

    # GP1 commands
    def gp1_reset
      @status = STAT_CMD_READY | STAT_DMA_READY | STAT_VRAM_TO_CPU_READY | STAT_DISPLAY_ENABLE
      @display_enabled = false
      @dma_direction = 0
      @display_start_x = 0
      @display_start_y = 0
      @display_h_start = 0x200
      @display_h_end = 0xC00
      @display_v_start = 0x10
      @display_v_end = 0x100
      @draw_area_left = 0
      @draw_area_top = 0
      @draw_area_right = 0
      @draw_area_bottom = 0
      @draw_offset_x = 0
      @draw_offset_y = 0
      @cmd_buffer = []
      @cmd_remaining = 0
      @vram_transfer_mode = nil
    end

    def gp1_reset_command_buffer
      @cmd_buffer = []
      @cmd_remaining = 0
      @vram_transfer_mode = nil
      @status |= STAT_CMD_READY
    end

    def gp1_acknowledge_irq
      @status &= ~STAT_IRQ
    end

    def gp1_display_enable(value)
      @display_enabled = (value & 0x01) == 0
    end

    def gp1_dma_direction(value)
      @dma_direction = value & 0x03
    end

    def gp1_display_start(value)
      @display_start_x = value & 0x3FE  # 10 bits, even
      @display_start_y = (value >> 10) & 0x1FF
    end

    def gp1_horizontal_range(value)
      @display_h_start = value & 0xFFF
      @display_h_end = (value >> 12) & 0xFFF
    end

    def gp1_vertical_range(value)
      @display_v_start = value & 0x3FF
      @display_v_end = (value >> 10) & 0x3FF
    end

    def gp1_display_mode(value)
      hr1 = value & 0x03
      @vertical_res = (value & 0x04) != 0 ? 480 : 240
      @video_mode = (value & 0x08) != 0 ? :pal : :ntsc
      @color_depth_24 = (value & 0x10) != 0
      @interlaced = (value & 0x20) != 0
      hr2 = (value & 0x40) != 0 ? 1 : 0

      @horizontal_res = case hr1
        when 0 then hr2 == 1 ? 368 : 256
        when 1 then 320
        when 2 then 512
        when 3 then 640
        else 320
      end

      # Update status
      @status = (@status & ~0x007F_0000) |
                ((hr1 << 17) & STAT_HORIZONTAL_RES1) |
                ((hr2 << 16) & STAT_HORIZONTAL_RES2) |
                ((@vertical_res == 480 ? 1 : 0) << 19) |
                ((@video_mode == :pal ? 1 : 0) << 20) |
                ((@color_depth_24 ? 1 : 0) << 21) |
                ((@interlaced ? 1 : 0) << 22)
    end

    def gp1_gpu_info(value)
      # GPU info - returns requested information
      # For now just acknowledge
    end

    # Software rendering
    def draw_pixel(x, y, r, g, b)
      return if x < @draw_area_left || x > @draw_area_right
      return if y < @draw_area_top || y > @draw_area_bottom
      return if x < 0 || x >= VRAM_WIDTH || y < 0 || y >= VRAM_HEIGHT

      idx = y * VRAM_WIDTH + x

      if @check_mask_bit && (@vram[idx] & 0x8000) != 0
        return  # Masked pixel
      end

      pixel = rgb_to_vram(r, g, b)
      pixel |= 0x8000 if @set_mask_bit

      @vram[idx] = pixel
    end

    def rgb_to_vram(r, g, b)
      ((r >> 3) & 0x1F) |
      (((g >> 3) & 0x1F) << 5) |
      (((b >> 3) & 0x1F) << 10)
    end

    def draw_rect(x, y, w, h, color)
      cr = color[:r]; cg = color[:g]; cb = color[:b]
      pixel = ((cr >> 3) & 0x1F) | (((cg >> 3) & 0x1F) << 5) | (((cb >> 3) & 0x1F) << 10)
      smb = @set_mask_bit
      pixel |= 0x8000 if smb
      cmb = @check_mask_bit
      al = @draw_area_left; ar = @draw_area_right
      at = @draw_area_top; ab = @draw_area_bottom
      vram = @vram
      h.times do |dy|
        py = y + dy
        next if py < at || py > ab || py < 0 || py >= VRAM_HEIGHT
        row = py * VRAM_WIDTH
        w.times do |dx|
          px = x + dx
          next if px < al || px > ar || px < 0 || px >= VRAM_WIDTH
          idx = row + px
          next if cmb && (vram[idx] & 0x8000) != 0
          vram[idx] = pixel
        end
      end
    end

    def draw_textured_rect(x, y, w, h, tex_u, tex_v, clut_x, clut_y, base_color, raw_texture)
      br = base_color[:r]; bg = base_color[:g]; bb = base_color[:b]
      tpx = @texture_page_x; tpy = @texture_page_y; tdp = @texture_depth
      al = @draw_area_left; ar = @draw_area_right
      at = @draw_area_top; ab = @draw_area_bottom
      cmb = @check_mask_bit; smb = @set_mask_bit
      vram = @vram
      h.times do |dy|
        py = y + dy
        next if py < at || py > ab || py < 0 || py >= VRAM_HEIGHT
        row = py * VRAM_WIDTH
        w.times do |dx|
          px = x + dx
          next if px < al || px > ar || px < 0 || px >= VRAM_WIDTH

          u = (tex_u + dx) & 0xFF
          v = (tex_v + dy) & 0xFF
          texel = sample_texture(u, v, clut_x, clut_y, tpx, tpy, tdp)
          next if texel == 0

          idx = row + px
          next if cmb && (vram[idx] & 0x8000) != 0

          if raw_texture
            out = texel
          else
            tr = (texel & 0x001F)
            tg = (texel & 0x03E0) >> 5
            tb = (texel & 0x7C00) >> 10
            r5 = ((tr * br) >> 7); r5 = 0x1F if r5 > 0x1F
            g5 = ((tg * bg) >> 7); g5 = 0x1F if g5 > 0x1F
            b5 = ((tb * bb) >> 7); b5 = 0x1F if b5 > 0x1F
            out = r5 | (g5 << 5) | (b5 << 10)
          end
          out |= 0x8000 if smb
          vram[idx] = out
        end
      end
    end

    def draw_line(x0, y0, x1, y1, c0, c1, gouraud)
      # Bresenham's line algorithm with optional color interpolation
      dx = (x1 - x0).abs
      dy = -(y1 - y0).abs
      sx = x0 < x1 ? 1 : -1
      sy = y0 < y1 ? 1 : -1
      err = dx + dy

      steps = [dx.abs, dy.abs].max
      steps = 1 if steps == 0

      loop do
        t = steps > 0 ? (gouraud ? ((x0 - x0).abs + (y0 - y0).abs).to_f / steps : 0) : 0
        if gouraud && steps > 0
          progress = ((x0 - x0).abs + (y0 - y0).abs).to_f / steps
          r = (c0[:r] + (c1[:r] - c0[:r]) * progress).to_i
          g = (c0[:g] + (c1[:g] - c0[:g]) * progress).to_i
          b = (c0[:b] + (c1[:b] - c0[:b]) * progress).to_i
        else
          r, g, b = c0[:r], c0[:g], c0[:b]
        end

        draw_pixel(x0, y0, r, g, b)

        break if x0 == x1 && y0 == y1

        e2 = 2 * err
        if e2 >= dy
          err += dy
          x0 += sx
        end
        if e2 <= dx
          err += dx
          y0 += sy
        end
      end
    end

    def draw_triangle(p0, p1, p2, c0, c1, c2, gouraud)
      # Simple scanline triangle rasterization
      # Sort vertices by Y
      verts = [[p0, c0], [p1, c1], [p2, c2]].sort_by { |v, _| v[:y] }
      v0, col0 = verts[0]
      v1, col1 = verts[1]
      v2, col2 = verts[2]

      return if v2[:y] == v0[:y]  # Degenerate triangle

      # Flat color if not gouraud
      unless gouraud
        col1 = col0
        col2 = col0
      end

      # Rasterize
      (v0[:y].to_i..v2[:y].to_i).each do |y|
        next if y < @draw_area_top || y > @draw_area_bottom

        # Find X bounds for this scanline
        if y < v1[:y]
          # Upper part of triangle
          next if v1[:y] == v0[:y]
          t1 = (y - v0[:y]).to_f / (v1[:y] - v0[:y])
          x1 = v0[:x] + (v1[:x] - v0[:x]) * t1
          c_left = interp_color(col0, col1, t1)
        else
          # Lower part of triangle
          next if v2[:y] == v1[:y]
          t1 = (y - v1[:y]).to_f / (v2[:y] - v1[:y])
          x1 = v1[:x] + (v2[:x] - v1[:x]) * t1
          c_left = interp_color(col1, col2, t1)
        end

        t2 = (y - v0[:y]).to_f / (v2[:y] - v0[:y])
        x2 = v0[:x] + (v2[:x] - v0[:x]) * t2
        c_right = interp_color(col0, col2, t2)

        # Ensure x1 < x2
        if x1 > x2
          x1, x2 = x2, x1
          c_left, c_right = c_right, c_left
        end

        # Draw scanline — inline draw_pixel to skip method-call overhead.
        x_start = [x1.to_i, @draw_area_left].max
        x_end = [x2.to_i, @draw_area_right].min
        next if y < 0 || y >= VRAM_HEIGHT
        row = y * VRAM_WIDTH
        cmb = @check_mask_bit; smb = @set_mask_bit
        vram = @vram

        if gouraud && x2 != x1
          inv_w = 1.0 / (x2 - x1)
          lr = c_left[:r]; lg = c_left[:g]; lb = c_left[:b]
          rr = c_right[:r]; rg = c_right[:g]; rb = c_right[:b]
          dr = rr - lr; dg = rg - lg; db = rb - lb
          (x_start..x_end).each do |x|
            next if x < 0 || x >= VRAM_WIDTH
            idx = row + x
            next if cmb && (vram[idx] & 0x8000) != 0
            t = (x - x1) * inv_w
            r = (lr + dr * t).to_i; r = 0 if r < 0; r = 255 if r > 255
            g = (lg + dg * t).to_i; g = 0 if g < 0; g = 255 if g > 255
            b = (lb + db * t).to_i; b = 0 if b < 0; b = 255 if b > 255
            pixel = ((r >> 3) & 0x1F) | (((g >> 3) & 0x1F) << 5) | (((b >> 3) & 0x1F) << 10)
            pixel |= 0x8000 if smb
            vram[idx] = pixel
          end
        else
          cr = c_left[:r]; cg = c_left[:g]; cb = c_left[:b]
          pixel = ((cr >> 3) & 0x1F) | (((cg >> 3) & 0x1F) << 5) | (((cb >> 3) & 0x1F) << 10)
          pixel |= 0x8000 if smb
          (x_start..x_end).each do |x|
            next if x < 0 || x >= VRAM_WIDTH
            idx = row + x
            next if cmb && (vram[idx] & 0x8000) != 0
            vram[idx] = pixel
          end
        end
      end
    end

    def interp_color(c0, c1, t)
      {
        r: (c0[:r] + (c1[:r] - c0[:r]) * t).to_i.clamp(0, 255),
        g: (c0[:g] + (c1[:g] - c0[:g]) * t).to_i.clamp(0, 255),
        b: (c0[:b] + (c1[:b] - c0[:b]) * t).to_i.clamp(0, 255)
      }
    end

    # Sample a texel from VRAM
    # Returns 15-bit color value or nil if transparent
    def sample_texture(u, v, clut_x, clut_y, tex_page_x, tex_page_y, tex_depth)
      # Apply texture window wrapping
      # Formula: texcoord = (texcoord AND NOT(Mask*8)) OR ((Offset AND Mask)*8)
      u = (u & ~(@texture_window_mask_x * 8)) | ((@texture_window_offset_x & @texture_window_mask_x) * 8)
      v = (v & ~(@texture_window_mask_y * 8)) | ((@texture_window_offset_y & @texture_window_mask_y) * 8)

      case tex_depth
      when 0  # 4-bit CLUT
        # Each 16-bit VRAM word holds 4 texels
        texel_x = tex_page_x + (u / 4)
        texel_y = tex_page_y + v
        word = @vram[(texel_y % VRAM_HEIGHT) * VRAM_WIDTH + (texel_x % VRAM_WIDTH)] || 0

        # Extract 4-bit index based on u position
        shift = (u & 3) * 4
        index = (word >> shift) & 0x0F

        # Look up in CLUT
        clut_addr = clut_y * VRAM_WIDTH + clut_x + index
        @vram[clut_addr] || 0

      when 1  # 8-bit CLUT
        # Each 16-bit VRAM word holds 2 texels
        texel_x = tex_page_x + (u / 2)
        texel_y = tex_page_y + v
        word = @vram[(texel_y % VRAM_HEIGHT) * VRAM_WIDTH + (texel_x % VRAM_WIDTH)] || 0

        # Extract 8-bit index
        shift = (u & 1) * 8
        index = (word >> shift) & 0xFF

        # Look up in CLUT
        clut_addr = clut_y * VRAM_WIDTH + clut_x + index
        @vram[clut_addr] || 0

      when 2  # 15-bit direct
        texel_x = tex_page_x + u
        texel_y = tex_page_y + v
        @vram[(texel_y % VRAM_HEIGHT) * VRAM_WIDTH + (texel_x % VRAM_WIDTH)] || 0

      else
        0
      end
    end

    # Convert 15-bit VRAM color to RGB hash
    def vram_to_rgb(color16)
      {
        r: (color16 & 0x001F) << 3,
        g: (color16 & 0x03E0) >> 2,
        b: (color16 & 0x7C00) >> 7
      }
    end

    # Check if texel is transparent (bit 15 = 0 and color = 0)
    def texel_transparent?(color16)
      color16 == 0
    end

    # Draw textured triangle with UV interpolation
    def draw_textured_triangle(p0, p1, p2, t0, t1, t2, base_color, clut, tex_page_x, tex_page_y, tex_depth, raw_texture)
      # Extract CLUT position
      clut_x = (clut & 0x3F) * 16
      clut_y = (clut >> 6) & 0x1FF

      # Sort vertices by Y, keeping UVs in sync
      verts = [[p0, t0], [p1, t1], [p2, t2]].sort_by { |v, _| v[:y] }
      v0, uv0 = verts[0]
      v1, uv1 = verts[1]
      v2, uv2 = verts[2]

      return if v2[:y] == v0[:y]  # Degenerate triangle

      # Rasterize with UV interpolation
      (v0[:y].to_i..v2[:y].to_i).each do |y|
        next if y < @draw_area_top || y > @draw_area_bottom

        # Find X bounds and interpolate UVs for this scanline
        if y < v1[:y]
          next if v1[:y] == v0[:y]
          t1_interp = (y - v0[:y]).to_f / (v1[:y] - v0[:y])
          x1 = v0[:x] + (v1[:x] - v0[:x]) * t1_interp
          u1 = uv0[:u] + (uv1[:u] - uv0[:u]) * t1_interp
          v1_tex = uv0[:v] + (uv1[:v] - uv0[:v]) * t1_interp
        else
          next if v2[:y] == v1[:y]
          t1_interp = (y - v1[:y]).to_f / (v2[:y] - v1[:y])
          x1 = v1[:x] + (v2[:x] - v1[:x]) * t1_interp
          u1 = uv1[:u] + (uv2[:u] - uv1[:u]) * t1_interp
          v1_tex = uv1[:v] + (uv2[:v] - uv1[:v]) * t1_interp
        end

        t2_interp = (y - v0[:y]).to_f / (v2[:y] - v0[:y])
        x2 = v0[:x] + (v2[:x] - v0[:x]) * t2_interp
        u2 = uv0[:u] + (uv2[:u] - uv0[:u]) * t2_interp
        v2_tex = uv0[:v] + (uv2[:v] - uv0[:v]) * t2_interp

        # Ensure x1 < x2
        if x1 > x2
          x1, x2 = x2, x1
          u1, u2 = u2, u1
          v1_tex, v2_tex = v2_tex, v1_tex
        end

        # Draw scanline with texture sampling
        x_start = [x1.to_i, @draw_area_left].max
        x_end = [x2.to_i, @draw_area_right].min
        x_span = x2 - x1

        inv_span = x_span > 0 ? 1.0 / x_span : 0
        du = u2 - u1
        dv = v2_tex - v1_tex
        br = base_color[:r]; bg = base_color[:g]; bb = base_color[:b]
        next if y < @draw_area_top || y > @draw_area_bottom || y < 0 || y >= VRAM_HEIGHT
        row = y * VRAM_WIDTH
        al = @draw_area_left; ar = @draw_area_right
        cmb = @check_mask_bit; smb = @set_mask_bit
        vram = @vram
        (x_start..x_end).each do |x|
          next if x < al || x > ar || x < 0 || x >= VRAM_WIDTH

          t = (x - x1) * inv_span
          u = (u1 + du * t).to_i & 0xFF
          v_coord = (v1_tex + dv * t).to_i & 0xFF

          texel = sample_texture(u, v_coord, clut_x, clut_y, tex_page_x, tex_page_y, tex_depth)
          next if texel == 0

          idx = row + x
          next if cmb && (vram[idx] & 0x8000) != 0

          if raw_texture
            out = texel
          else
            tr = (texel & 0x001F)
            tg = (texel & 0x03E0) >> 5
            tb = (texel & 0x7C00) >> 10
            r5 = ((tr * br) >> 7); r5 = 0x1F if r5 > 0x1F
            g5 = ((tg * bg) >> 7); g5 = 0x1F if g5 > 0x1F
            b5 = ((tb * bb) >> 7); b5 = 0x1F if b5 > 0x1F
            out = r5 | (g5 << 5) | (b5 << 10)
          end
          out |= 0x8000 if smb
          vram[idx] = out
        end
      end
    end
  end
end
