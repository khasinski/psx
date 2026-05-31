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

    def initialize(title: "PSX-Ruby", config: nil)
      SDL2.init(SDL2::INIT_VIDEO)

      @config = config
      @window = SDL2::Window.create(
        title,
        SDL2::Window::POS_CENTERED,
        SDL2::Window::POS_CENTERED,
        WIDTH * SCALE,
        HEIGHT * SCALE,
        0
      )

      @renderer = @window.create_renderer(-1, SDL2::Renderer::Flags::ACCELERATED)
      @renderer.draw_blend_mode = SDL2::BlendMode::BLEND

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
      @font = try_open_font

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

      if rgba && !@has_rendered_content
        has_content = rgba.getbyte(0) != 0 || rgba.getbyte(rgba.bytesize / 2) != 0
        @has_rendered_content = true if has_content
      end

      if rgba && @has_rendered_content
        @rgba_buffer = rgba
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
      @font&.destroy
      @renderer.destroy
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
