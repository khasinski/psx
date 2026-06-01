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
    DITHER_MATRIX = [
      [-4, 0, -3, 1],
      [2, -2, 3, -1],
      [-3, 1, -4, 0],
      [3, -1, 2, -2]
    ].freeze
    DITHER_OFFSETS = DITHER_MATRIX.flatten.freeze

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
      @texture_x_flip = false
      @texture_y_flip = false
      @texture_disable_allow = false

      # Mask settings
      @set_mask_bit = false
      @check_mask_bit = false

      # Command buffer for multi-word commands
      @cmd_buffer = []
      @cmd_remaining = 0
      @current_cmd = 0
      @polyline_active = false

      # VRAM transfer state
      @vram_transfer_x = 0
      @vram_transfer_y = 0
      @vram_transfer_start_x = 0  # Starting X for line wrap detection
      @vram_transfer_width = 0
      @vram_transfer_height = 0
      @vram_transfer_count = 0
      @vram_transfer_pixels_remaining = 0
      @vram_transfer_mode = nil  # :cpu_to_vram or :vram_to_cpu
      @vram_read_buffer = []

      # Framebuffer caching
      @framebuffer_dirty = true
      @framebuffer_cache = nil
      @texture_clut_cache_store = {}
      @gpu_info_latch = 0

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
        value = @vram_read_buffer.shift
        @gpu_info_latch = value
        @vram_transfer_mode = nil if @vram_read_buffer.empty?
        value
      else
        @gpu_info_latch
      end
    end

    # GP0 - Rendering commands and VRAM access
    def gp0(value)
      if @polyline_active
        handle_polyline_word(value)
        return
      end

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
      @cmd_buffer.clear
      @cmd_buffer << value

      if cmd == CMD_NOP
        # Do nothing
      elsif cmd == CMD_CLEAR_CACHE
        # Clear texture cache - no software cache is modeled yet
      elsif cmd == CMD_FILL_RECT
        @cmd_remaining = 2
      elsif cmd >= 0x20 && cmd <= 0x3F
        # Polygons
        @cmd_remaining = polygon_word_count(cmd) - 1
      elsif cmd >= 0x40 && cmd <= 0x5F
        # Lines
        if (cmd & 0x08) != 0
          @polyline_active = true
        else
          @cmd_remaining = line_word_count(cmd) - 1
        end
      elsif cmd >= 0x60 && cmd <= 0x7F
        # Rectangles
        @cmd_remaining = rectangle_word_count(cmd) - 1
      elsif cmd == CMD_COPY_VRAM_VRAM
        @cmd_remaining = 3
      elsif cmd == CMD_COPY_CPU_VRAM
        @cmd_remaining = 2
      elsif cmd == CMD_COPY_VRAM_CPU
        @cmd_remaining = 2
      elsif cmd == 0xE1
        gp0_draw_mode(value)
      elsif cmd == 0xE2
        gp0_texture_window(value)
      elsif cmd == 0xE3
        gp0_draw_area_top_left(value)
      elsif cmd == 0xE4
        gp0_draw_area_bottom_right(value)
      elsif cmd == 0xE5
        gp0_draw_offset(value)
      elsif cmd == 0xE6
        gp0_mask_settings(value)
      else
        # Unknown command - ignore
      end

      execute_gp0_command if !@polyline_active && @cmd_remaining == 0 && @cmd_buffer.length > 0
    end

    # GP1 - Display control
    def gp1(value)
      cmd = (value >> 24) & 0xFF

      if cmd == 0x00
        gp1_reset
      elsif cmd == 0x01
        gp1_reset_command_buffer
      elsif cmd == 0x02
        gp1_acknowledge_irq
      elsif cmd == 0x03
        gp1_display_enable(value)
      elsif cmd == 0x04
        gp1_dma_direction(value)
      elsif cmd == 0x05
        gp1_display_start(value)
      elsif cmd == 0x06
        gp1_horizontal_range(value)
      elsif cmd == 0x07
        gp1_vertical_range(value)
      elsif cmd == 0x08
        gp1_display_mode(value)
      elsif cmd == 0x09
        gp1_texture_disable(value)
      elsif cmd >= 0x10 && cmd <= 0x1F
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
         @framebuffer_cache[:height] == @vertical_res &&
         @framebuffer_cache[:display_start_x] == @display_start_x &&
         @framebuffer_cache[:display_start_y] == @display_start_y &&
         @framebuffer_cache[:color_depth_24] == @color_depth_24 &&
         @framebuffer_cache[:display_enabled] == @display_enabled
        return @framebuffer_cache
      end

      width = @horizontal_res
      height = @vertical_res
      num_pixels = width * height

      # Build RGBA array and pack once (faster than building string)
      rgba_arr = Array.new(num_pixels * 4)
      dst_i = 0

      if !@display_enabled
        num_pixels.times do
          rgba_arr[dst_i] = 0
          rgba_arr[dst_i + 1] = 0
          rgba_arr[dst_i + 2] = 0
          rgba_arr[dst_i + 3] = 255
          dst_i += 4
        end
      else
        height.times do |y|
          if @color_depth_24
            base_byte = ((@display_start_y + y) * VRAM_WIDTH + @display_start_x) * 2
            width.times do |x|
              r = vram_byte(base_byte + x * 3)
              g = vram_byte(base_byte + x * 3 + 1)
              b = vram_byte(base_byte + x * 3 + 2)
              rgba_arr[dst_i] = r
              rgba_arr[dst_i + 1] = g
              rgba_arr[dst_i + 2] = b
              rgba_arr[dst_i + 3] = 255
              dst_i += 4
            end
          else
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
        end
      end

      @framebuffer_dirty = false
      @framebuffer_cache = {
        width: width,
        height: height,
        display_start_x: @display_start_x,
        display_start_y: @display_start_y,
        color_depth_24: @color_depth_24,
        display_enabled: @display_enabled,
        rgba: rgba_arr.pack("C*")
      }
    end

    # Mark framebuffer as needing regeneration (call when VRAM is modified)
    def mark_dirty
      @framebuffer_dirty = true
    end

    private

    def vram_byte(byte_offset)
      byte_offset %= VRAM_WIDTH * VRAM_HEIGHT * 2
      word = @vram[byte_offset >> 1] || 0
      if byte_offset.even?
        word & 0xFF
      else
        (word >> 8) & 0xFF
      end
    end

    # GP0 command execution
    def execute_gp0_command
      cmd = @current_cmd
      if cmd == CMD_FILL_RECT
        mark_dirty
        gp0_fill_rect
      elsif cmd >= 0x20 && cmd <= 0x3F
        mark_dirty
        gp0_polygon
      elsif cmd >= 0x40 && cmd <= 0x5F
        mark_dirty
        gp0_line
      elsif cmd >= 0x60 && cmd <= 0x7F
        mark_dirty
        gp0_rectangle
      elsif cmd == CMD_COPY_VRAM_VRAM
        mark_dirty
        gp0_copy_vram_vram
      elsif cmd == CMD_COPY_CPU_VRAM
        mark_dirty
        gp0_copy_cpu_vram
      elsif cmd == CMD_COPY_VRAM_CPU
        gp0_copy_vram_cpu  # Reading from VRAM doesn't modify it
      end

      @cmd_buffer.clear
      @current_cmd = 0
    end

    def handle_polyline_word(value)
      if value == 0x5555_5555 || value == 0x5000_5000
        mark_dirty
        gp0_polyline
        @cmd_buffer.clear
        @current_cmd = 0
        @polyline_active = false
      else
        @cmd_buffer << value
      end
    end

    # Word counts for multi-word commands
    def polygon_word_count(cmd)
      # Bit 4: Gouraud (adds a color word for each vertex past the first)
      # Bit 2: Textured (adds UV+CLUT/UV+TexPage/UV word per vertex)
      # Bit 3: Quad (4 vertices vs 3)
      gouraud = (cmd & 0x10) != 0
      textured = (cmd & 0x04) != 0
      quad = (cmd & 0x08) != 0

      vertices = quad ? 4 : 3
      words = 1                              # cmd + first vertex colour
      words += vertices                      # one position word per vertex
      words += vertices if textured          # one texcoord word per vertex
      words += (vertices - 1) if gouraud     # one extra colour for verts 2..N
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
      clear_texture_clut_cache
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

      if textured
        idx = 0

        c = @cmd_buffer[idx]
        r0 = c & 0xFF; g0 = (c >> 8) & 0xFF; b0 = (c >> 16) & 0xFF
        idx += 1
        pos = @cmd_buffer[idx]
        x0 = gpu_vertex_coord(pos) + @draw_offset_x
        y0 = gpu_vertex_coord(pos >> 16) + @draw_offset_y
        idx += 1
        tc = @cmd_buffer[idx]
        u0 = tc & 0xFF; v0 = (tc >> 8) & 0xFF; clut = (tc >> 16) & 0xFFFF
        idx += 1

        if gouraud
          c = @cmd_buffer[idx]
          r1 = c & 0xFF; g1 = (c >> 8) & 0xFF; b1 = (c >> 16) & 0xFF
          idx += 1
        else
          r1 = r0; g1 = g0; b1 = b0
        end
        pos = @cmd_buffer[idx]
        x1 = gpu_vertex_coord(pos) + @draw_offset_x
        y1 = gpu_vertex_coord(pos >> 16) + @draw_offset_y
        idx += 1
        tc = @cmd_buffer[idx]
        u1 = tc & 0xFF; v1 = (tc >> 8) & 0xFF; tpage = (tc >> 16) & 0xFFFF
        idx += 1

        if gouraud
          c = @cmd_buffer[idx]
          r2 = c & 0xFF; g2 = (c >> 8) & 0xFF; b2 = (c >> 16) & 0xFF
          idx += 1
        else
          r2 = r0; g2 = g0; b2 = b0
        end
        pos = @cmd_buffer[idx]
        x2 = gpu_vertex_coord(pos) + @draw_offset_x
        y2 = gpu_vertex_coord(pos >> 16) + @draw_offset_y
        idx += 1
        tc = @cmd_buffer[idx]
        u2 = tc & 0xFF; v2 = (tc >> 8) & 0xFF
        idx += 1

        tex_page_x = (tpage & 0x0F) * 64
        tex_page_y = ((tpage >> 4) & 0x01) * 256
        tex_depth = (tpage >> 7) & 0x03
        apply_texture_page(tpage, preserve_draw_mode_bits: true)

        draw_textured_triangle(x0, y0, u0, v0, r0, g0, b0,
                               x1, y1, u1, v1, r1, g1, b1,
                               x2, y2, u2, v2, r2, g2, b2,
                               clut, tex_page_x, tex_page_y, tex_depth,
                               raw_texture, semi_transparent)

        if quad
          if gouraud
            c = @cmd_buffer[idx]
            r3 = c & 0xFF; g3 = (c >> 8) & 0xFF; b3 = (c >> 16) & 0xFF
            idx += 1
          else
            r3 = r0; g3 = g0; b3 = b0
          end
          pos = @cmd_buffer[idx]
          x3 = gpu_vertex_coord(pos) + @draw_offset_x
          y3 = gpu_vertex_coord(pos >> 16) + @draw_offset_y
          idx += 1
          tc = @cmd_buffer[idx]
          u3 = tc & 0xFF; v3 = (tc >> 8) & 0xFF

          draw_textured_triangle(x1, y1, u1, v1, r1, g1, b1,
                                 x2, y2, u2, v2, r2, g2, b2,
                                 x3, y3, u3, v3, r3, g3, b3,
                                 clut, tex_page_x, tex_page_y, tex_depth,
                                 raw_texture, semi_transparent)
        end

        return
      end

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
        x = gpu_vertex_coord(pos)
        y = gpu_vertex_coord(pos >> 16)
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
        apply_texture_page(tpage, preserve_draw_mode_bits: true)

        if quad
          draw_textured_triangle(points[0], points[1], points[2],
                                 texcoords[0], texcoords[1], texcoords[2],
                                 colors[0], colors[1], colors[2], gouraud,
                                 clut, tex_page_x, tex_page_y, tex_depth, raw_texture, semi_transparent)
          draw_textured_triangle(points[1], points[2], points[3],
                                 texcoords[1], texcoords[2], texcoords[3],
                                 colors[1], colors[2], colors[3], gouraud,
                                 clut, tex_page_x, tex_page_y, tex_depth, raw_texture, semi_transparent)
        else
          draw_textured_triangle(points[0], points[1], points[2],
                                 texcoords[0], texcoords[1], texcoords[2],
                                 colors[0], colors[1], colors[2], gouraud,
                                 clut, tex_page_x, tex_page_y, tex_depth, raw_texture, semi_transparent)
        end
      else
        if quad
          draw_triangle(points[0], points[1], points[2], colors[0], colors[1], colors[2], gouraud, semi_transparent)
          draw_triangle(points[1], points[2], points[3], colors[1], colors[2], colors[3], gouraud, semi_transparent)
        else
          draw_triangle(points[0], points[1], points[2], colors[0], colors[1], colors[2], gouraud, semi_transparent)
        end
      end
    end

    def gp0_line
      cmd = @current_cmd
      gouraud = (cmd & 0x10) != 0
      semi_transparent = (cmd & 0x02) != 0

      c0 = @cmd_buffer[0]
      color0 = { r: c0 & 0xFF, g: (c0 >> 8) & 0xFF, b: (c0 >> 16) & 0xFF }

      pos0 = @cmd_buffer[1]
      x0 = gpu_vertex_coord(pos0)
      y0 = gpu_vertex_coord(pos0 >> 16)

      if gouraud
        c1 = @cmd_buffer[2]
        color1 = { r: c1 & 0xFF, g: (c1 >> 8) & 0xFF, b: (c1 >> 16) & 0xFF }
        pos1 = @cmd_buffer[3]
      else
        color1 = color0
        pos1 = @cmd_buffer[2]
      end

      x1 = gpu_vertex_coord(pos1)
      y1 = gpu_vertex_coord(pos1 >> 16)

      draw_line(
        x0 + @draw_offset_x, y0 + @draw_offset_y,
        x1 + @draw_offset_x, y1 + @draw_offset_y,
        color0, color1, gouraud, semi_transparent
      )
    end

    def gp0_polyline
      cmd = @current_cmd
      gouraud = (cmd & 0x10) != 0
      semi_transparent = (cmd & 0x02) != 0
      return if @cmd_buffer.length < 3

      color0 = line_color(@cmd_buffer[0])
      pos0 = line_point(@cmd_buffer[1])
      idx = 2

      while idx < @cmd_buffer.length
        if gouraud
          break if idx + 1 >= @cmd_buffer.length

          color1 = line_color(@cmd_buffer[idx])
          pos1 = line_point(@cmd_buffer[idx + 1])
          draw_line(pos0[:x] + @draw_offset_x, pos0[:y] + @draw_offset_y,
                    pos1[:x] + @draw_offset_x, pos1[:y] + @draw_offset_y,
                    color0, color1, true, semi_transparent)
          color0 = color1
          pos0 = pos1
          idx += 2
        else
          pos1 = line_point(@cmd_buffer[idx])
          draw_line(pos0[:x] + @draw_offset_x, pos0[:y] + @draw_offset_y,
                    pos1[:x] + @draw_offset_x, pos1[:y] + @draw_offset_y,
                    color0, color0, false, semi_transparent)
          pos0 = pos1
          idx += 1
        end
      end
    end

    def line_color(word)
      { r: word & 0xFF, g: (word >> 8) & 0xFF, b: (word >> 16) & 0xFF }
    end

    def gpu_vertex_coord(value)
      value &= 0x7FF
      value >= 0x400 ? value - 0x800 : value
    end

    def line_point(word)
      { x: gpu_vertex_coord(word), y: gpu_vertex_coord(word >> 16) }
    end

    def gp0_rectangle
      cmd = @current_cmd
      textured = (cmd & 0x04) != 0
      raw_texture = (cmd & 0x01) != 0
      semi_transparent = (cmd & 0x02) != 0
      size_mode = (cmd >> 3) & 0x3

      c = @cmd_buffer[0]
      color = { r: c & 0xFF, g: (c >> 8) & 0xFF, b: (c >> 16) & 0xFF }

      pos = @cmd_buffer[1]
      x = gpu_vertex_coord(gpu_vertex_coord(pos) + @draw_offset_x)
      y = gpu_vertex_coord(gpu_vertex_coord(pos >> 16) + @draw_offset_y)

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
        w = dims & 0x3FF
        h = (dims >> 16) & 0x1FF
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
        draw_textured_rect(x, y, w, h, tex_u, tex_v, clut_x, clut_y, color, raw_texture, semi_transparent)
      else
        draw_rect(x, y, w, h, color, semi_transparent)
      end
    end

    def gp0_copy_vram_vram
      clear_texture_clut_cache
      src = @cmd_buffer[1]
      dst = @cmd_buffer[2]
      size = @cmd_buffer[3]

      src_x = src & 0x3FF
      src_y = (src >> 16) & 0x1FF
      dst_x = dst & 0x3FF
      dst_y = (dst >> 16) & 0x1FF
      w = (((size & 0x3FF) - 1) & 0x3FF) + 1
      h = ((((size >> 16) & 0x1FF) - 1) & 0x1FF) + 1

      return if src_x == dst_x && src_y == dst_y && !@set_mask_bit

      horizontal_wrap = src_x + w > VRAM_WIDTH || dst_x + w > VRAM_WIDTH
      same_row_overlap = !horizontal_wrap && src_y == dst_y && src_x < dst_x && dst_x < src_x + w

      if !@set_mask_bit && !@check_mask_bit && !same_row_overlap
        h.times do |dy|
          w.times do |dx|
            sx = (src_x + dx) % VRAM_WIDTH
            sy = (src_y + dy) % VRAM_HEIGHT
            dx2 = (dst_x + dx) % VRAM_WIDTH
            dy2 = (dst_y + dy) % VRAM_HEIGHT
            @vram[dy2 * VRAM_WIDTH + dx2] = @vram[sy * VRAM_WIDTH + sx]
          end
        end
        return
      end

      h.times do |dy|
        sy = (src_y + dy) % VRAM_HEIGHT
        dy2 = (dst_y + dy) % VRAM_HEIGHT
        copy_reverse = sy == dy2 &&
                       (src_x < dst_x || ((src_x + w - 1) % VRAM_WIDTH) < ((dst_x + w - 1) % VRAM_WIDTH))
        dx = copy_reverse ? w - 1 : 0
        while copy_reverse ? dx >= 0 : dx < w
          sx = (src_x + dx) % VRAM_WIDTH
          dx2 = (dst_x + dx) % VRAM_WIDTH
          dst_idx = dy2 * VRAM_WIDTH + dx2
          if !@check_mask_bit || (@vram[dst_idx] & 0x8000) == 0
            pixel = @vram[sy * VRAM_WIDTH + sx]
            @vram[dst_idx] = pixel | (@set_mask_bit ? 0x8000 : 0)
          end
          dx += copy_reverse ? -1 : 1
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
      @vram_transfer_pixels_remaining = w * h
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

      # Read pixels in transfer order and pack GPUREAD words across row boundaries.
      @vram_read_buffer = []
      pending_pixel = nil
      h.times do |dy|
        row_start = ((y + dy) % VRAM_HEIGHT) * VRAM_WIDTH
        w.times do |dx|
          pixel = @vram[row_start + ((x + dx) % VRAM_WIDTH)]
          if pending_pixel
            @vram_read_buffer << ((pixel << 16) | pending_pixel)
            pending_pixel = nil
          else
            pending_pixel = pixel
          end
        end
      end
      @vram_read_buffer << pending_pixel if pending_pixel

      @vram_transfer_mode = :vram_to_cpu
      @status |= STAT_VRAM_TO_CPU_READY
    end

    def vram_write_data(value)
      return if @vram_transfer_count <= 0

      if @vram_transfer_pixels_remaining > 0
        vram_write_pixel(value & 0xFFFF)
        @vram_transfer_pixels_remaining -= 1
      end
      if @vram_transfer_pixels_remaining > 0
        vram_write_pixel((value >> 16) & 0xFFFF)
        @vram_transfer_pixels_remaining -= 1
      end

      @vram_transfer_count -= 1

      if @vram_transfer_count <= 0
        @vram_transfer_mode = nil
        @vram_transfer_pixels_remaining = 0
        @status |= STAT_CMD_READY
      end
    end

    def vram_write_pixel(pixel)
      clear_texture_clut_cache unless @texture_clut_cache_store.empty?
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
      apply_texture_page(value, preserve_draw_mode_bits: false)
    end

    def apply_texture_page(value, preserve_draw_mode_bits:)
      @texture_page_x = (value & 0x0F) * 64
      @texture_page_y = ((value >> 4) & 0x01) * 256
      @semi_transparency = (value >> 5) & 0x03
      @texture_depth = (value >> 7) & 0x03
      unless preserve_draw_mode_bits
        @texture_x_flip = (value & (1 << 12)) != 0
        @texture_y_flip = (value & (1 << 13)) != 0
      end

      status_mask = preserve_draw_mode_bits ? 0x01FF : 0x07FF
      @status = (@status & ~status_mask) | (value & status_mask)

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
      clear_texture_clut_cache
      @status = STAT_CMD_READY | STAT_DMA_READY | STAT_VRAM_TO_CPU_READY | STAT_DISPLAY_ENABLE
      @display_enabled = false
      @dma_direction = 0
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
      @draw_area_left = 0
      @draw_area_top = 0
      @draw_area_right = 0
      @draw_area_bottom = 0
      @draw_offset_x = 0
      @draw_offset_y = 0
      @texture_page_x = 0
      @texture_page_y = 0
      @texture_depth = 0
      @semi_transparency = 0
      @texture_window_mask_x = 0
      @texture_window_mask_y = 0
      @texture_window_offset_x = 0
      @texture_window_offset_y = 0
      @texture_x_flip = false
      @texture_y_flip = false
      @texture_disable_allow = false
      @set_mask_bit = false
      @check_mask_bit = false
      @cmd_buffer.clear
      @cmd_remaining = 0
      @vram_transfer_mode = nil
      @polyline_active = false
      mark_dirty
    end

    def gp1_reset_command_buffer
      @cmd_buffer.clear
      @cmd_remaining = 0
      @vram_transfer_mode = nil
      @polyline_active = false
      @status |= STAT_CMD_READY
    end

    def gp1_acknowledge_irq
      @status &= ~STAT_IRQ
    end

    def gp1_display_enable(value)
      enabled = (value & 0x01) == 0
      if @display_enabled != enabled
        @display_enabled = enabled
        mark_dirty
      end
    end

    def gp1_dma_direction(value)
      @dma_direction = value & 0x03
    end

    def gp1_display_start(value)
      @display_start_x = value & 0x3FE  # 10 bits, even
      @display_start_y = (value >> 10) & 0x1FF
      mark_dirty
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
      mark_dirty
    end

    def gp1_gpu_info(value)
      @gpu_info_latch = case value & 0x0F
      when 0x02
        @texture_window_mask_x |
          (@texture_window_mask_y << 5) |
          (@texture_window_offset_x << 10) |
          (@texture_window_offset_y << 15)
      when 0x03
        @draw_area_left | (@draw_area_top << 10)
      when 0x04
        @draw_area_right | (@draw_area_bottom << 10)
      when 0x05
        (@draw_offset_x & 0x7FF) | ((@draw_offset_y & 0x7FF) << 11)
      when 0x07
        2
      else
        @gpu_info_latch
      end
    end

    # Software rendering
    def draw_pixel(x, y, r, g, b, dither: false, semi: false)
      return if x < @draw_area_left || x > @draw_area_right
      return if y < @draw_area_top || y > @draw_area_bottom
      return if x < 0 || x >= VRAM_WIDTH || y < 0 || y >= VRAM_HEIGHT

      idx = y * VRAM_WIDTH + x

      if @check_mask_bit && (@vram[idx] & 0x8000) != 0
        return  # Masked pixel
      end

      if dither
        r5 = dither_channel_to_5bit(r, x, y)
        g5 = dither_channel_to_5bit(g, x, y)
        b5 = dither_channel_to_5bit(b, x, y)
      else
        r5 = dither_channel_to_5bit(r, 3, 2)
        g5 = dither_channel_to_5bit(g, 3, 2)
        b5 = dither_channel_to_5bit(b, 3, 2)
      end

      r5, g5, b5 = stp_blend5(@vram[idx], r5, g5, b5, @semi_transparency) if semi

      pixel = r5 | (g5 << 5) | (b5 << 10)
      pixel |= 0x8000 if @set_mask_bit

      @vram[idx] = pixel
    end

    def rgb_to_vram(r, g, b)
      ((r >> 3) & 0x1F) |
      (((g >> 3) & 0x1F) << 5) |
      (((b >> 3) & 0x1F) << 10)
    end

    def draw_rect(x, y, w, h, color, semi = false)
      cr = color[:r]; cg = color[:g]; cb = color[:b]
      dither = (@status & STAT_DITHER) != 0
      fr5 = dither_channel_to_5bit(cr, 3, 2)
      fg5 = dither_channel_to_5bit(cg, 3, 2)
      fb5 = dither_channel_to_5bit(cb, 3, 2)
      pixel_opaque = fr5 | (fg5 << 5) | (fb5 << 10)
      smb = @set_mask_bit
      pixel_opaque |= 0x8000 if smb
      cmb = @check_mask_bit
      al = @draw_area_left; ar = @draw_area_right
      at = @draw_area_top; ab = @draw_area_bottom
      vram = @vram
      stp_mode = semi ? @semi_transparency : -1
      h.times do |dy|
        py = y + dy
        next if py < at || py > ab || py < 0 || py >= VRAM_HEIGHT
        row = py * VRAM_WIDTH
        w.times do |dx|
          px = x + dx
          next if px < al || px > ar || px < 0 || px >= VRAM_WIDTH
          idx = row + px
          bg = vram[idx]
          next if cmb && (bg & 0x8000) != 0
          if dither
            pr5 = dither_channel_to_5bit(cr, px, py)
            pg5 = dither_channel_to_5bit(cg, px, py)
            pb5 = dither_channel_to_5bit(cb, px, py)
            if stp_mode >= 0
              pr5, pg5, pb5 = stp_blend5(bg, pr5, pg5, pb5, stp_mode)
            end
            pix = pr5 | (pg5 << 5) | (pb5 << 10)
            pix |= 0x8000 if smb
            vram[idx] = pix
          elsif stp_mode >= 0
            r5, g5, b5 = stp_blend5(bg, fr5, fg5, fb5, stp_mode)
            pix = r5 | (g5 << 5) | (b5 << 10)
            pix |= 0x8000 if smb
            vram[idx] = pix
          else
            vram[idx] = pixel_opaque
          end
        end
      end
    end

    def draw_textured_rect(x, y, w, h, tex_u, tex_v, clut_x, clut_y, base_color, raw_texture, semi = false)
      br = base_color[:r]; bg_c = base_color[:g]; bb = base_color[:b]
      tpx = @texture_page_x; tpy = @texture_page_y; tdp = @texture_depth
      clut_cache = texture_clut_cache(clut_x, clut_y, tdp)
      al = @draw_area_left; ar = @draw_area_right
      at = @draw_area_top; ab = @draw_area_bottom
      cmb = @check_mask_bit; smb = @set_mask_bit
      vram = @vram
      stp_mode = semi ? @semi_transparency : -1
      use_dither = (@status & STAT_DITHER) != 0
      tex_u_mask = ~(@texture_window_mask_x * 8)
      tex_v_mask = ~(@texture_window_mask_y * 8)
      tex_u_offset = (@texture_window_offset_x & @texture_window_mask_x) * 8
      tex_v_offset = (@texture_window_offset_y & @texture_window_mask_y) * 8
      h.times do |dy|
        py = y + dy
        next if py < at || py > ab || py < 0 || py >= VRAM_HEIGHT
        row = py * VRAM_WIDTH
        dither_y = (py & 3) << 2
        w.times do |dx|
          px = x + dx
          next if px < al || px > ar || px < 0 || px >= VRAM_WIDTH

          u = (((tex_u + dx) & 0xFF) & tex_u_mask) | tex_u_offset
          v = (((tex_v + dy) & 0xFF) & tex_v_mask) | tex_v_offset
          texel = case tdp
                  when 0
                    word = vram[((tpy + v) % VRAM_HEIGHT) * VRAM_WIDTH + ((tpx + (u >> 2)) % VRAM_WIDTH)] || 0
                    clut_cache[(word >> ((u & 3) << 2)) & 0x0F]
                  when 1
                    word = vram[((tpy + v) % VRAM_HEIGHT) * VRAM_WIDTH + ((tpx + (u >> 1)) % VRAM_WIDTH)] || 0
                    clut_cache[(word >> ((u & 1) << 3)) & 0xFF]
                  else
                    vram[((tpy + v) % VRAM_HEIGHT) * VRAM_WIDTH + ((tpx + u) % VRAM_WIDTH)] || 0
                  end
          next if texel == 0

          idx = row + px
          bg = vram[idx]
          next if cmb && (bg & 0x8000) != 0

          if raw_texture
            fr5 = texel & 0x1F
            fg5 = (texel >> 5) & 0x1F
            fb5 = (texel >> 10) & 0x1F
          else
            tr = (texel & 0x001F)
            tg = (texel & 0x03E0) >> 5
            tb = (texel & 0x7C00) >> 10
            offset = use_dither ? DITHER_OFFSETS[dither_y | (px & 3)] : 0
            fr5 = (((tr * br) >> 4) + offset) >> 3
            fg5 = (((tg * bg_c) >> 4) + offset) >> 3
            fb5 = (((tb * bb) >> 4) + offset) >> 3
            fr5 = 0 if fr5 < 0; fr5 = 0x1F if fr5 > 0x1F
            fg5 = 0 if fg5 < 0; fg5 = 0x1F if fg5 > 0x1F
            fb5 = 0 if fb5 < 0; fb5 = 0x1F if fb5 > 0x1F
          end

          # Texel STP bit (bit 15) gates semi-transparency on a per-pixel
          # basis for textured primitives.
          if stp_mode >= 0 && (texel & 0x8000) != 0
            fr5, fg5, fb5 = stp_blend5(bg, fr5, fg5, fb5, stp_mode)
          end

          out = fr5 | (fg5 << 5) | (fb5 << 10)
          out |= texel & 0x8000
          out |= 0x8000 if smb
          vram[idx] = out
        end
      end
    end

    def draw_line(x0, y0, x1, y1, c0, c1, gouraud, semi = false)
      # Bresenham's line algorithm with optional color interpolation
      dx = (x1 - x0).abs
      dy = -(y1 - y0).abs
      sx = x0 < x1 ? 1 : -1
      sy = y0 < y1 ? 1 : -1
      err = dx + dy

      steps = [dx.abs, dy.abs].max
      steps = 1 if steps == 0

      step = 0
      dither = (@status & STAT_DITHER) != 0
      loop do
        if gouraud && steps > 0
          progress = step.to_f / steps
          r = (c0[:r] + (c1[:r] - c0[:r]) * progress).to_i
          g = (c0[:g] + (c1[:g] - c0[:g]) * progress).to_i
          b = (c0[:b] + (c1[:b] - c0[:b]) * progress).to_i
        else
          r, g, b = c0[:r], c0[:g], c0[:b]
        end

        draw_pixel(x0, y0, r, g, b, dither: dither, semi: semi)

        break if x0 == x1 && y0 == y1

        step += 1
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

    def draw_triangle(p0, p1, p2, c0, c1, c2, gouraud, semi = false)
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

      # Rasterize. Pre-clamp y to the draw area + VRAM bounds so the inner
      # loops can drop their per-scanline bounds checks. The `while (y += 1)`
      # idiom keeps `next` semantics from the original each-block.
      y_lo = v0[:y].to_i
      y_hi = v2[:y].to_i
      y_lo = @draw_area_top    if y_lo < @draw_area_top
      y_hi = @draw_area_bottom if y_hi > @draw_area_bottom
      y_lo = 0                 if y_lo < 0
      y_hi = VRAM_HEIGHT - 1   if y_hi > VRAM_HEIGHT - 1
      cmb = @check_mask_bit; smb = @set_mask_bit
      vram = @vram
      stp_mode = semi ? @semi_transparency : -1
      dither = (@status & STAT_DITHER) != 0

      y = y_lo - 1
      while (y += 1) <= y_hi
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
        # x_start/x_end clamp to [draw_area_left, draw_area_right], which
        # are themselves in [0, VRAM_WIDTH); no per-pixel bounds check.
        x_start = [x1.ceil, @draw_area_left].max
        x_end = [x2.floor, @draw_area_right].min
        row = y * VRAM_WIDTH

        if gouraud && x2 != x1
          inv_w = 1.0 / (x2 - x1)
          lr = c_left[:r]; lg = c_left[:g]; lb = c_left[:b]
          rr = c_right[:r]; rg = c_right[:g]; rb = c_right[:b]
          dr = rr - lr; dg = rg - lg; db = rb - lb
          x = x_start - 1
          while (x += 1) <= x_end
            idx = row + x
            bg = vram[idx]
            next if cmb && (bg & 0x8000) != 0
            t = (x - x1) * inv_w
            r = (lr + dr * t).to_i; r = 0 if r < 0; r = 255 if r > 255
            g = (lg + dg * t).to_i; g = 0 if g < 0; g = 255 if g > 255
            b = (lb + db * t).to_i; b = 0 if b < 0; b = 255 if b > 255
            if dither
              fr = dither_channel_to_5bit(r, x, y)
              fg = dither_channel_to_5bit(g, x, y)
              fb = dither_channel_to_5bit(b, x, y)
            else
              fr = dither_channel_to_5bit(r, 3, 2)
              fg = dither_channel_to_5bit(g, 3, 2)
              fb = dither_channel_to_5bit(b, 3, 2)
            end
            if stp_mode >= 0
              fr, fg, fb = stp_blend5(bg, fr, fg, fb, stp_mode)
            end
            pixel = fr | (fg << 5) | (fb << 10)
            pixel |= 0x8000 if smb
            vram[idx] = pixel
          end
        else
          cr = c_left[:r]; cg = c_left[:g]; cb = c_left[:b]
          fr_const = dither_channel_to_5bit(cr, 3, 2)
          fg_const = dither_channel_to_5bit(cg, 3, 2)
          fb_const = dither_channel_to_5bit(cb, 3, 2)
          opaque_pixel = fr_const | (fg_const << 5) | (fb_const << 10)
          opaque_pixel |= 0x8000 if smb
          if !dither && !cmb && stp_mode < 0 && x_end >= x_start
            # Pure opaque flat fill — the Sony logo and most BIOS UI hit
            # this path. Array#fill is a single C-level memset over the
            # span; we previously ran a 100-1000 iteration Ruby loop per
            # scanline doing the same constant store.
            vram.fill(opaque_pixel, row + x_start, x_end - x_start + 1)
          else
            x = x_start - 1
            while (x += 1) <= x_end
              idx = row + x
              bg = vram[idx]
              next if cmb && (bg & 0x8000) != 0
              if dither
                r5 = dither_channel_to_5bit(cr, x, y)
                g5 = dither_channel_to_5bit(cg, x, y)
                b5 = dither_channel_to_5bit(cb, x, y)
                r5, g5, b5 = stp_blend5(bg, r5, g5, b5, stp_mode) if stp_mode >= 0
                pixel = r5 | (g5 << 5) | (b5 << 10)
                pixel |= 0x8000 if smb
                vram[idx] = pixel
              elsif stp_mode >= 0
                r5, g5, b5 = stp_blend5(bg, fr_const, fg_const, fb_const, stp_mode)
                pixel = r5 | (g5 << 5) | (b5 << 10)
                pixel |= 0x8000 if smb
                vram[idx] = pixel
              else
                vram[idx] = opaque_pixel
              end
            end
          end
        end
      end
    end

    # 5-bit-per-channel semi-transparency blend. Returns [r5, g5, b5].
    # Mode 0: B/2 + F/2     (50% mix)
    # Mode 1: B + F         (additive, clamp to 31)
    # Mode 2: B - F         (subtractive, clamp at 0)
    # Mode 3: B + F/4       (25% additive)
    def stp_blend5(bg, fr, fg, fb, mode)
      br = bg & 0x1F; bgg = (bg >> 5) & 0x1F; bb = (bg >> 10) & 0x1F
      case mode
      when 0
        [(br + fr) >> 1, (bgg + fg) >> 1, (bb + fb) >> 1]
      when 1
        r = br + fr; r = 0x1F if r > 0x1F
        g = bgg + fg; g = 0x1F if g > 0x1F
        b = bb + fb; b = 0x1F if b > 0x1F
        [r, g, b]
      when 2
        r = br - fr; r = 0 if r < 0
        g = bgg - fg; g = 0 if g < 0
        b = bb - fb; b = 0 if b < 0
        [r, g, b]
      else
        r = br + (fr >> 2); r = 0x1F if r > 0x1F
        g = bgg + (fg >> 2); g = 0x1F if g > 0x1F
        b = bb + (fb >> 2); b = 0x1F if b > 0x1F
        [r, g, b]
      end
    end

    def dither_channel_to_5bit(value, x, y)
      dithered = (value + DITHER_OFFSETS[((y & 3) << 2) | (x & 3)]) >> 3
      return 0 if dithered < 0
      return 0x1F if dithered > 0x1F

      dithered
    end

    def dither_modulated_texel_channel(texel_5bit, color_8bit, x, y)
      dither_channel_to_5bit((texel_5bit * color_8bit) >> 4, x, y)
    end

    def modulated_texel_channel(texel_5bit, color_8bit, x, y)
      value = (texel_5bit * color_8bit) >> 4
      if (@status & STAT_DITHER) != 0
        dither_channel_to_5bit(value, x, y)
      else
        # DuckStation's no-dither path still indexes the dither LUT at
        # matrix coordinate [2][3], whose current matrix bias is zero.
        dither_channel_to_5bit(value, 3, 2)
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
    def texture_clut_cache(clut_x, clut_y, tex_depth)
      entries =
        case tex_depth
        when 0 then 16
        when 1 then 256
        else return nil
        end

      key = (tex_depth << 19) | ((clut_y % VRAM_HEIGHT) << 10) | (clut_x % VRAM_WIDTH)
      cached = @texture_clut_cache_store[key]
      return cached if cached

      row = (clut_y % VRAM_HEIGHT) * VRAM_WIDTH
      cache = Array.new(entries, 0)
      i = -1
      while (i += 1) < entries
        cache[i] = @vram[row + ((clut_x + i) % VRAM_WIDTH)] || 0
      end
      @texture_clut_cache_store[key] = cache
    end

    def clear_texture_clut_cache
      @texture_clut_cache_store.clear
    end

    def sample_texture(u, v, clut_x, clut_y, tex_page_x, tex_page_y, tex_depth, clut_cache = nil)
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
        clut_cache ? clut_cache[index] : (@vram[(clut_y % VRAM_HEIGHT) * VRAM_WIDTH + ((clut_x + index) % VRAM_WIDTH)] || 0)

      when 1  # 8-bit CLUT
        # Each 16-bit VRAM word holds 2 texels
        texel_x = tex_page_x + (u / 2)
        texel_y = tex_page_y + v
        word = @vram[(texel_y % VRAM_HEIGHT) * VRAM_WIDTH + (texel_x % VRAM_WIDTH)] || 0

        # Extract 8-bit index
        shift = (u & 1) * 8
        index = (word >> shift) & 0xFF

        # Look up in CLUT
        clut_cache ? clut_cache[index] : (@vram[(clut_y % VRAM_HEIGHT) * VRAM_WIDTH + ((clut_x + index) % VRAM_WIDTH)] || 0)

      when 2, 3  # 15-bit direct; mode 3 is reserved but aliases direct color
        texel_x = tex_page_x + u
        texel_y = tex_page_y + v
        @vram[(texel_y % VRAM_HEIGHT) * VRAM_WIDTH + (texel_x % VRAM_WIDTH)] || 0

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
    def draw_textured_triangle(x0, y0, u0, v0_tex, c0r, c0g, c0b,
                               x1, y1, u1, v1_tex_in, c1r, c1g, c1b,
                               x2, y2, u2, v2_tex_in, c2r, c2g, c2b,
                               clut, tex_page_x, tex_page_y, tex_depth, raw_texture, semi = false)
      # Extract CLUT position
      clut_x = (clut & 0x3F) * 16
      clut_y = (clut >> 6) & 0x1FF
      clut_cache = texture_clut_cache(clut_x, clut_y, tex_depth)

      if y0 > y1
        x0, x1 = x1, x0; y0, y1 = y1, y0
        u0, u1 = u1, u0; v0_tex, v1_tex_in = v1_tex_in, v0_tex
        c0r, c1r = c1r, c0r; c0g, c1g = c1g, c0g; c0b, c1b = c1b, c0b
      end
      if y1 > y2
        x1, x2 = x2, x1; y1, y2 = y2, y1
        u1, u2 = u2, u1; v1_tex_in, v2_tex_in = v2_tex_in, v1_tex_in
        c1r, c2r = c2r, c1r; c1g, c2g = c2g, c1g; c1b, c2b = c2b, c1b
      end
      if y0 > y1
        x0, x1 = x1, x0; y0, y1 = y1, y0
        u0, u1 = u1, u0; v0_tex, v1_tex_in = v1_tex_in, v0_tex
        c0r, c1r = c1r, c0r; c0g, c1g = c1g, c0g; c0b, c1b = c1b, c0b
      end

      return if y2 == y0  # Degenerate triangle

      vx0 = x0; vy0 = y0; vu0 = u0; vv0 = v0_tex
      vx1 = x1; vy1 = y1; vu1 = u1; vv1 = v1_tex_in
      vx2 = x2; vy2 = y2; vu2 = u2; vv2 = v2_tex_in

      # Rasterize with UV interpolation. y pre-clamped so the per-scanline
      # y bounds check is gone; inner x loop's bounds check is also dead
      # because x_start/x_end are already clamped to [draw_area_left,
      # draw_area_right] which sits inside [0, VRAM_WIDTH).
      y_lo = vy0.to_i
      y_hi = vy2.to_i
      y_lo = @draw_area_top    if y_lo < @draw_area_top
      y_hi = @draw_area_bottom if y_hi > @draw_area_bottom
      y_lo = 0                 if y_lo < 0
      y_hi = VRAM_HEIGHT - 1   if y_hi > VRAM_HEIGHT - 1
      cmb = @check_mask_bit; smb = @set_mask_bit
      vram = @vram
      stp_mode = semi ? @semi_transparency : -1
      use_dither = (@status & STAT_DITHER) != 0
      tex_u_mask = ~(@texture_window_mask_x * 8)
      tex_v_mask = ~(@texture_window_mask_y * 8)
      tex_u_offset = (@texture_window_offset_x & @texture_window_mask_x) * 8
      tex_v_offset = (@texture_window_offset_y & @texture_window_mask_y) * 8

      y = y_lo - 1
      while (y += 1) <= y_hi
        # Find X bounds and interpolate UVs for this scanline
        if y < vy1
          next if vy1 == vy0
          t1_interp = (y - vy0).to_f / (vy1 - vy0)
          x1 = vx0 + (vx1 - vx0) * t1_interp
          u1 = vu0 + (vu1 - vu0) * t1_interp
          v1_tex = vv0 + (vv1 - vv0) * t1_interp
          lr = (c0r + (c1r - c0r) * t1_interp).to_i; lr = 0 if lr < 0; lr = 255 if lr > 255
          lg = (c0g + (c1g - c0g) * t1_interp).to_i; lg = 0 if lg < 0; lg = 255 if lg > 255
          lb = (c0b + (c1b - c0b) * t1_interp).to_i; lb = 0 if lb < 0; lb = 255 if lb > 255
        else
          next if vy2 == vy1
          t1_interp = (y - vy1).to_f / (vy2 - vy1)
          x1 = vx1 + (vx2 - vx1) * t1_interp
          u1 = vu1 + (vu2 - vu1) * t1_interp
          v1_tex = vv1 + (vv2 - vv1) * t1_interp
          lr = (c1r + (c2r - c1r) * t1_interp).to_i; lr = 0 if lr < 0; lr = 255 if lr > 255
          lg = (c1g + (c2g - c1g) * t1_interp).to_i; lg = 0 if lg < 0; lg = 255 if lg > 255
          lb = (c1b + (c2b - c1b) * t1_interp).to_i; lb = 0 if lb < 0; lb = 255 if lb > 255
        end

        t2_interp = (y - vy0).to_f / (vy2 - vy0)
        x2 = vx0 + (vx2 - vx0) * t2_interp
        u2 = vu0 + (vu2 - vu0) * t2_interp
        v2_tex = vv0 + (vv2 - vv0) * t2_interp
        rr = (c0r + (c2r - c0r) * t2_interp).to_i; rr = 0 if rr < 0; rr = 255 if rr > 255
        rg = (c0g + (c2g - c0g) * t2_interp).to_i; rg = 0 if rg < 0; rg = 255 if rg > 255
        rb = (c0b + (c2b - c0b) * t2_interp).to_i; rb = 0 if rb < 0; rb = 255 if rb > 255

        # Ensure x1 < x2
        if x1 > x2
          x1, x2 = x2, x1
          u1, u2 = u2, u1
          v1_tex, v2_tex = v2_tex, v1_tex
          lr, rr = rr, lr
          lg, rg = rg, lg
          lb, rb = rb, lb
        end

        # Draw scanline with texture sampling
        x_start = [x1.ceil, @draw_area_left].max
        x_end = [x2.floor, @draw_area_right].min
        x_span = x2 - x1

        inv_span = x_span > 0 ? 1.0 / x_span : 0
        du = u2 - u1
        dv = v2_tex - v1_tex
        dr = rr - lr; dg = rg - lg; db = rb - lb
        row = y * VRAM_WIDTH
        dither_y = (y & 3) << 2

        t = (x_start - x1) * inv_span
        cur_u = ((u1 + du * t) * 65_536).to_i
        cur_v = ((v1_tex + dv * t) * 65_536).to_i
        cur_r = ((lr + dr * t) * 65_536).to_i
        cur_g = ((lg + dg * t) * 65_536).to_i
        cur_b = ((lb + db * t) * 65_536).to_i
        step_u = (du * inv_span * 65_536).to_i
        step_v = (dv * inv_span * 65_536).to_i
        step_r = (dr * inv_span * 65_536).to_i
        step_g = (dg * inv_span * 65_536).to_i
        step_b = (db * inv_span * 65_536).to_i

        x = x_start - 1
        while (x += 1) <= x_end
          u = (((cur_u >> 16) & 0xFF) & tex_u_mask) | tex_u_offset
          v_coord = (((cur_v >> 16) & 0xFF) & tex_v_mask) | tex_v_offset

          texel = case tex_depth
                  when 0
                    word = vram[((tex_page_y + v_coord) % VRAM_HEIGHT) * VRAM_WIDTH + ((tex_page_x + (u >> 2)) % VRAM_WIDTH)] || 0
                    clut_cache[(word >> ((u & 3) << 2)) & 0x0F]
                  when 1
                    word = vram[((tex_page_y + v_coord) % VRAM_HEIGHT) * VRAM_WIDTH + ((tex_page_x + (u >> 1)) % VRAM_WIDTH)] || 0
                    clut_cache[(word >> ((u & 1) << 3)) & 0xFF]
                  else
                    vram[((tex_page_y + v_coord) % VRAM_HEIGHT) * VRAM_WIDTH + ((tex_page_x + u) % VRAM_WIDTH)] || 0
                  end

          if texel != 0
            idx = row + x
            bg = vram[idx]

            unless cmb && (bg & 0x8000) != 0
              if raw_texture
                fr5 = texel & 0x1F
                fg5 = (texel >> 5) & 0x1F
                fb5 = (texel >> 10) & 0x1F
              else
                br = cur_r >> 16; br = 0 if br < 0; br = 255 if br > 255
                bg_c = cur_g >> 16; bg_c = 0 if bg_c < 0; bg_c = 255 if bg_c > 255
                bb = cur_b >> 16; bb = 0 if bb < 0; bb = 255 if bb > 255
                tr = (texel & 0x001F)
                tg = (texel & 0x03E0) >> 5
                tb = (texel & 0x7C00) >> 10
                offset = use_dither ? DITHER_OFFSETS[dither_y | (x & 3)] : 0
                fr5 = (((tr * br) >> 4) + offset) >> 3
                fg5 = (((tg * bg_c) >> 4) + offset) >> 3
                fb5 = (((tb * bb) >> 4) + offset) >> 3
                fr5 = 0 if fr5 < 0; fr5 = 0x1F if fr5 > 0x1F
                fg5 = 0 if fg5 < 0; fg5 = 0x1F if fg5 > 0x1F
                fb5 = 0 if fb5 < 0; fb5 = 0x1F if fb5 > 0x1F
              end

              if stp_mode >= 0 && (texel & 0x8000) != 0
                fr5, fg5, fb5 = stp_blend5(bg, fr5, fg5, fb5, stp_mode)
              end

              out = fr5 | (fg5 << 5) | (fb5 << 10)
              out |= texel & 0x8000
              out |= 0x8000 if smb
              vram[idx] = out
            end
          end

          cur_u += step_u
          cur_v += step_v
          cur_r += step_r
          cur_g += step_g
          cur_b += step_b
        end
      end
    end
  end
end
