# frozen_string_literal: true

require "sdl2"

module PSX
  class Display
    WIDTH = 320
    HEIGHT = 240
    SCALE = 2  # 640x480 window

    # PS1 controller button bits (active-low).
    BUTTON_BITS = {
      "select"   => 0,
      "l3"       => 1,
      "r3"       => 2,
      "start"    => 3,
      "up"       => 4,
      "right"    => 5,
      "down"     => 6,
      "left"     => 7,
      "l2"       => 8,
      "r2"       => 9,
      "l1"       => 10,
      "r1"       => 11,
      "triangle" => 12,
      "circle"   => 13,
      "cross"    => 14,
      "square"   => 15
    }.freeze

    # Reserved scancodes that the front-end binds for its own UI and
    # must never be assigned to a PSX button.
    RESERVED_SCANCODES = [
      SDL2::Key::Scan::ESCAPE,
      SDL2::Key::Scan::TAB,
      SDL2::Key::Scan::F5,
      SDL2::Key::Scan::F6,
      SDL2::Key::Scan::F8
    ].freeze

    # macOS ships these monospace TTFs by default; pick the first one
    # that loads. Linux/Windows users can drop in their own path via
    # PSX_FONT.
    FONT_CANDIDATES = [
      ENV["PSX_FONT"],
      "/System/Library/Fonts/Menlo.ttc",
      "/System/Library/Fonts/Monaco.ttf",
      "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
      "C:/Windows/Fonts/consola.ttf"
    ].compact.freeze

    GL_PRESENTER_LOAD_ERROR = begin
      require "ffi"

      class GLPresenter
        extend FFI::Library

        ffi_lib [
          "/System/Library/Frameworks/OpenGL.framework/OpenGL",
          "GL",
          "libGL.so.1"
        ]

      GL_COLOR_BUFFER_BIT = 0x0000_4000
      GL_TEXTURE_2D = 0x0DE1
      GL_RGBA = 0x1908
      GL_UNSIGNED_BYTE = 0x1401
      GL_TEXTURE_MIN_FILTER = 0x2801
      GL_TEXTURE_MAG_FILTER = 0x2800
      GL_TEXTURE_ENV = 0x2300
      GL_TEXTURE_ENV_MODE = 0x2200
      GL_REPLACE = 0x1E01
      GL_NEAREST = 0x2600
      GL_UNPACK_ALIGNMENT = 0x0CF5
      GL_PROJECTION = 0x1701
      GL_MODELVIEW = 0x1700
      GL_QUADS = 0x0007
      GL_DEPTH_TEST = 0x0B71
      GL_CULL_FACE = 0x0B44

      attach_function :glViewport, %i[int int int int], :void
      attach_function :glMatrixMode, %i[uint], :void
      attach_function :glLoadIdentity, [], :void
      attach_function :glOrtho, %i[double double double double double double], :void
      attach_function :glEnable, %i[uint], :void
      attach_function :glDisable, %i[uint], :void
      attach_function :glClearColor, %i[float float float float], :void
      attach_function :glClear, %i[uint], :void
      attach_function :glGenTextures, %i[int pointer], :void
      attach_function :glDeleteTextures, %i[int pointer], :void
      attach_function :glBindTexture, %i[uint uint], :void
      attach_function :glTexParameteri, %i[uint uint int], :void
      attach_function :glTexEnvi, %i[uint uint int], :void
      attach_function :glPixelStorei, %i[uint int], :void
      attach_function :glTexImage2D, %i[uint int int int int int uint uint pointer], :void
      attach_function :glTexSubImage2D, %i[uint int int int int int uint uint pointer], :void
      attach_function :glColor4f, %i[float float float float], :void
      attach_function :glBegin, %i[uint], :void
      attach_function :glEnd, [], :void
      attach_function :glTexCoord2f, %i[float float], :void
      attach_function :glVertex2f, %i[float float], :void

        def initialize(window, width, height)
          @window = window
          @width = width
          @height = height
          verbose = $VERBOSE
          $VERBOSE = nil
          begin
            @context = SDL2::GL::Context.create(window)
          ensure
            $VERBOSE = verbose
          end
          @context.make_current(window)
          SDL2::GL.swap_interval = 0

          tex_ptr = FFI::MemoryPointer.new(:uint, 1)
          self.class.glGenTextures(1, tex_ptr)
          @texture_id = tex_ptr.read_uint
          self.class.glBindTexture(GL_TEXTURE_2D, @texture_id)
          self.class.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
          self.class.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
          self.class.glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE)
          self.class.glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
          self.class.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
        end

        def present(rgba, width, height)
          resize_texture(width, height) if width != @width || height != @height
          self.class.glBindTexture(GL_TEXTURE_2D, @texture_id)
          self.class.glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba)

          drawable_w, drawable_h = @window.gl_drawable_size
          self.class.glViewport(0, 0, drawable_w, drawable_h)
          self.class.glMatrixMode(GL_PROJECTION)
          self.class.glLoadIdentity
          self.class.glOrtho(0.0, 1.0, 1.0, 0.0, -1.0, 1.0)
          self.class.glMatrixMode(GL_MODELVIEW)
          self.class.glLoadIdentity
          self.class.glClearColor(0.0, 0.0, 0.0, 1.0)
          self.class.glClear(GL_COLOR_BUFFER_BIT)
          self.class.glDisable(GL_DEPTH_TEST)
          self.class.glDisable(GL_CULL_FACE)
          self.class.glEnable(GL_TEXTURE_2D)
          self.class.glColor4f(1.0, 1.0, 1.0, 1.0)

          self.class.glBegin(GL_QUADS)
          self.class.glTexCoord2f(0.0, 0.0); self.class.glVertex2f(0.0, 0.0)
          self.class.glTexCoord2f(1.0, 0.0); self.class.glVertex2f(1.0, 0.0)
          self.class.glTexCoord2f(1.0, 1.0); self.class.glVertex2f(1.0, 1.0)
          self.class.glTexCoord2f(0.0, 1.0); self.class.glVertex2f(0.0, 1.0)
          self.class.glEnd

          @window.gl_swap
        end

        def destroy
          if @texture_id
            tex_ptr = FFI::MemoryPointer.new(:uint, 1)
            tex_ptr.write_uint(@texture_id)
            self.class.glDeleteTextures(1, tex_ptr)
            @texture_id = nil
          end
          @context&.destroy
          @context = nil
        end

        private

        def resize_texture(width, height)
          @width = width
          @height = height
          self.class.glBindTexture(GL_TEXTURE_2D, @texture_id)
          self.class.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
        end
      end

      nil
    rescue LoadError, FFI::LoadError => e
      remove_const(:GLPresenter) if const_defined?(:GLPresenter, false)
      e
    end

    def initialize(title: "PSX-Ruby", config: nil, renderer: nil)
      SDL2.init(SDL2::INIT_VIDEO)

      @config = config
      @renderer_backend = (renderer || ENV["PSX_DISPLAY_RENDERER"] || "sdl").downcase
      window_flags = @renderer_backend == "gl" ? SDL2::Window::Flags::OPENGL : 0
      @window = SDL2::Window.create(
        title,
        SDL2::Window::POS_CENTERED,
        SDL2::Window::POS_CENTERED,
        WIDTH * SCALE,
        HEIGHT * SCALE,
        window_flags
      )

      if @renderer_backend == "gl"
        if GL_PRESENTER_LOAD_ERROR
          warn "OpenGL presenter unavailable: #{GL_PRESENTER_LOAD_ERROR.message}; falling back to SDL"
          @renderer_backend = "sdl"
        else
          @gl_presenter = GLPresenter.new(@window, WIDTH, HEIGHT)
          @renderer = nil
        end
      end

      if @renderer_backend == "sdl"
        @renderer = @window.create_renderer(-1, SDL2::Renderer::Flags::ACCELERATED)
        @renderer.draw_blend_mode = SDL2::BlendMode::BLEND
      else
        @renderer = nil
      end

      # Input state
      @quit_requested = false
      @controller_state = 0xFFFF  # All buttons released (active low)
      @save_state_requested = false
      @load_state_requested = false
      @debug_snapshot_requested = false

      # Settings overlay state
      @overlay_mode = nil     # nil | :menu | :rebind
      @overlay_cursor = 0     # index into Config::BUTTONS
      @rebind_button = nil    # button name being rebound

      # Build initial scancode->button map from config.
      rebuild_key_map!

      # Try to bring up SDL_ttf for the overlay. Failure is non-fatal —
      # we fall back to a single-row window-title overlay.
      @font = @renderer ? try_open_font : nil

      # Performance tracking
      @frame_count = 0
      @last_fps_time = Time.now
      @fps = 0

      @texture = nil
      @rgba_buffer = "\x00".b * (WIDTH * HEIGHT * 4)
      @rgba_buffer_size = WIDTH * HEIGHT * 4
      @has_rendered_content = false
    end

    def update(framebuffer)
      width = framebuffer[:width]
      height = framebuffer[:height]

      rgba = framebuffer[:rgba]

      if rgba
        @rgba_buffer = rgba
        @has_rendered_content = true
      else
        buffer_size = width * height * 4
        if @loading_screen_size != buffer_size
          rgba_arr = []
          height.times do |y|
            width.times do |x|
              if (x % 32 < 2) || (y % 32 < 2)
                rgba_arr.push(40, 40, 80, 255)
              else
                rgba_arr.push(0, 0, 40, 255)
              end
            end
          end
          @loading_screen = rgba_arr.pack("C*")
          @loading_screen_size = buffer_size
        end
        @rgba_buffer = @loading_screen
      end

      if @gl_presenter
        @gl_presenter.present(@rgba_buffer, width, height)
      else
        surface = SDL2::Surface.from_string(
          @rgba_buffer,
          width,
          height,
          32,
          width * 4,
          0x000000FF,
          0x0000FF00,
          0x00FF0000,
          0xFF000000
        )

        @texture&.destroy
        @texture = @renderer.create_texture_from(surface)
        surface.destroy

        @renderer.copy(@texture, nil, nil)
        draw_overlay if @overlay_mode
        @renderer.present
      end

      @frame_count += 1
      @total_frames = (@total_frames || 0) + 1
      now = Time.now
      elapsed = now - @last_fps_time
      if elapsed >= 1.0
        @fps = (@frame_count / elapsed).round(1)
        status = @has_rendered_content ? "RENDERING" : "Loading..."
        title = if @overlay_mode
                  overlay_title_string
                else
                  "PSX-Ruby - #{@fps} FPS - Frame #{@total_frames} - #{status}"
                end
        @window.title = title
        @frame_count = 0
        @last_fps_time = now
      end
    end

    def poll_events
      while (event = SDL2::Event.poll)
        case event
        when SDL2::Event::Quit
          @quit_requested = true
        when SDL2::Event::KeyDown
          handle_key(event.scancode, true)
        when SDL2::Event::KeyUp
          handle_key(event.scancode, false)
        end
      end
    end

    def quit_requested?
      @quit_requested
    end

    def take_save_request!
      r = @save_state_requested
      @save_state_requested = false
      r
    end

    def take_load_request!
      r = @load_state_requested
      @load_state_requested = false
      r
    end

    def take_debug_snapshot_request!
      r = @debug_snapshot_requested
      @debug_snapshot_requested = false
      r
    end

    def flash_status(msg)
      @window.title = "PSX-Ruby - #{msg}"
    end

    def controller_state
      @controller_state
    end

    def close
      @texture&.destroy
      @gl_presenter&.destroy
      @font&.destroy
      @renderer&.destroy
      @window.destroy
    end

    # Rebuild the scancode→button-bit lookup from @config.keys. Called
    # at startup and after every rebind so a stale map can't survive.
    def rebuild_key_map!
      @key_to_button = {}
      return unless @config

      Config::BUTTONS.each do |button|
        name = @config.keys[button]
        scancode = self.class.scancode_for(name)
        next unless scancode
        next if RESERVED_SCANCODES.include?(scancode)

        @key_to_button[scancode] = BUTTON_BITS.fetch(button)
      end
    end

    # Resolve a human-readable key name ("Z", "Up", "Return") to a
    # numeric SDL scancode. Returns nil for unknown names.
    def self.scancode_for(name)
      return nil unless name.is_a?(String) && !name.empty?

      const = name.upcase
      const = "RETURN" if const == "ENTER"
      SDL2::Key::Scan.const_get(const)
    rescue NameError
      nil
    end

    # Reverse of scancode_for: a scancode → "Z" / "Up" / "Return".
    # Used when the overlay records a fresh rebind.
    def self.name_for(scancode)
      SDL2::Key::Scan.constants.each do |const|
        return prettify_const(const.to_s) if SDL2::Key::Scan.const_get(const) == scancode
      end
      nil
    end

    def self.prettify_const(name)
      # Single character or all-caps two letters look like "Z" / "F8";
      # multi-letter names render nicer Capitalised ("Up", "Return").
      if name.length <= 2 || name.start_with?("F") && name[1..].match?(/\A\d+\z/)
        name
      else
        name[0] + name[1..].downcase
      end
    end

    private

    def try_open_font
      SDL2::TTF.init
      FONT_CANDIDATES.each do |path|
        next unless path && File.exist?(path)
        return SDL2::TTF.open(path, 13)
      rescue StandardError
        next
      end
      nil
    rescue StandardError
      nil
    end

    def handle_key(scancode, pressed)
      # Rebind mode swallows the next key entirely.
      if @overlay_mode == :rebind && pressed
        if scancode == SDL2::Key::Scan::ESCAPE
          @overlay_mode = :menu
          @rebind_button = nil
        elsif !RESERVED_SCANCODES.include?(scancode)
          assign_binding(@rebind_button, scancode)
          @overlay_mode = :menu
          @rebind_button = nil
        end
        return
      end

      if @overlay_mode == :menu && pressed
        case scancode
        when SDL2::Key::Scan::ESCAPE, SDL2::Key::Scan::TAB
          @overlay_mode = nil
        when SDL2::Key::Scan::UP
          @overlay_cursor = (@overlay_cursor - 1) % Config::BUTTONS.length
        when SDL2::Key::Scan::DOWN
          @overlay_cursor = (@overlay_cursor + 1) % Config::BUTTONS.length
        when SDL2::Key::Scan::RETURN
          @rebind_button = Config::BUTTONS[@overlay_cursor]
          @overlay_mode = :rebind
        end
        return
      end

      # Open the overlay on Tab.
      if pressed && scancode == SDL2::Key::Scan::TAB
        @overlay_mode = :menu
        return
      end

      if scancode == SDL2::Key::Scan::ESCAPE && pressed
        @quit_requested = true
        return
      end

      if pressed
        case scancode
        when SDL2::Key::Scan::F5 then @save_state_requested = true; return
        when SDL2::Key::Scan::F6 then @debug_snapshot_requested = true; return
        when SDL2::Key::Scan::F8 then @load_state_requested = true; return
        end
      end

      button = @key_to_button[scancode]
      return unless button

      if pressed
        @controller_state &= ~(1 << button)
      else
        @controller_state |= (1 << button)
      end
    end

    def assign_binding(button, scancode)
      return unless @config && button

      name = self.class.name_for(scancode)
      return unless name

      # Drop the old binding for this scancode if it was on another
      # button — every key can drive at most one button.
      @config.keys.each do |other, n|
        @config.keys[other] = nil if other != button && self.class.scancode_for(n) == scancode
      end
      @config.keys[button] = name
      Config::BUTTONS.each { |b| @config.keys[b] ||= Config::DEFAULTS["keys"][b] }
      rebuild_key_map!
      begin
        @config.save!
      rescue StandardError => e
        warn "[psx] failed to save config: #{e.message}"
      end
    end

    def overlay_title_string
      if @overlay_mode == :rebind
        "PSX-Ruby cfg  >> press a key for #{@rebind_button.upcase} (Esc cancel)"
      else
        button = Config::BUTTONS[@overlay_cursor]
        bound = @config ? @config.keys[button] : "?"
        "PSX-Ruby cfg  > #{button.upcase} = #{bound}   (Up/Down nav, Enter rebind, Tab/Esc close)"
      end
    end

    def draw_overlay
      return unless @overlay_mode

      win_w = WIDTH * SCALE
      win_h = HEIGHT * SCALE

      # Dim the game underneath.
      @renderer.draw_color = [0, 0, 0, 180]
      @renderer.fill_rect(SDL2::Rect.new(0, 0, win_w, win_h))

      return draw_overlay_fallback unless @font

      # Panel
      panel_w = 380
      panel_h = 360
      panel_x = (win_w - panel_w) / 2
      panel_y = (win_h - panel_h) / 2
      @renderer.draw_color = [20, 20, 40, 230]
      @renderer.fill_rect(SDL2::Rect.new(panel_x, panel_y, panel_w, panel_h))
      @renderer.draw_color = [180, 180, 220, 255]
      @renderer.draw_rect(SDL2::Rect.new(panel_x, panel_y, panel_w, panel_h))

      header = (@overlay_mode == :rebind) ? "REBIND: press a key (Esc cancel)" : "PSX-Ruby settings"
      render_text_line(header, panel_x + 12, panel_y + 8, [255, 255, 255])

      line_y = panel_y + 32
      line_h = @font.line_skip
      Config::BUTTONS.each_with_index do |button, idx|
        selected = (idx == @overlay_cursor)
        prefix = selected ? ">" : " "
        bound = @config ? @config.keys[button] : "?"
        color = selected ? [255, 220, 120] : [200, 200, 200]
        text = format("%s %-9s  %s", prefix, button, bound)
        render_text_line(text, panel_x + 12, line_y, color)
        line_y += line_h
      end

      # Footer: read-only paths + key hints.
      line_y += 6
      if @config
        render_text_line("quicksave : #{@config.quicksave_path}", panel_x + 12, line_y, [140, 160, 200])
        line_y += line_h
        render_text_line("snapshot  : #{@config.debug_snapshot_prefix}", panel_x + 12, line_y, [140, 160, 200])
        line_y += line_h
      end
      render_text_line("Up/Down nav  Enter rebind  Tab/Esc close", panel_x + 12, line_y + 4, [120, 200, 160])
    end

    def render_text_line(text, x, y, color)
      surface = @font.render_blended(text, color)
      texture = @renderer.create_texture_from(surface)
      dest = SDL2::Rect.new(x, y, surface.w, surface.h)
      @renderer.copy(texture, nil, dest)
      texture.destroy
      surface.destroy
    end

    def draw_overlay_fallback
      # No font: the window title already shows the current row, but
      # add a centered tinted band on the canvas so the user notices.
      bar_h = 32
      bar_y = (HEIGHT * SCALE - bar_h) / 2
      @renderer.draw_color = [20, 20, 40, 230]
      @renderer.fill_rect(SDL2::Rect.new(0, bar_y, WIDTH * SCALE, bar_h))
    end
  end
end
