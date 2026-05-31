# frozen_string_literal: true

require "sdl2"

module PSX
  class Display
    WIDTH = 320
    HEIGHT = 240
    SCALE = 2  # 640x480 window

    def initialize(title: "PSX-Ruby")
      SDL2.init(SDL2::INIT_VIDEO)

      @window = SDL2::Window.create(
        title,
        SDL2::Window::POS_CENTERED,
        SDL2::Window::POS_CENTERED,
        WIDTH * SCALE,
        HEIGHT * SCALE,
        0
      )

      @renderer = @window.create_renderer(-1, SDL2::Renderer::Flags::ACCELERATED)

      # Input state
      @quit_requested = false
      @controller_state = 0xFFFF  # All buttons released (active low)
      # Save-state request flags — set by F5/F8 in handle_key, consumed by
      # the emulator loop in run_with_display (under the emulation mutex so
      # the snapshot is taken between CPU steps).
      @save_state_requested = false
      @load_state_requested = false
      @debug_snapshot_requested = false

      # Performance tracking
      @frame_count = 0
      @last_fps_time = Time.now
      @fps = 0

      # Cache texture reference
      @texture = nil

      # Pre-allocated RGBA buffer (320x240x4 = 307,200 bytes)
      @rgba_buffer = "\x00".b * (WIDTH * HEIGHT * 4)
      @rgba_buffer_size = WIDTH * HEIGHT * 4

      # Track if we've seen real content
      @has_rendered_content = false
    end

    def update(framebuffer)
      width = framebuffer[:width]
      height = framebuffer[:height]

      # GPU now provides pre-packed RGBA string
      rgba = framebuffer[:rgba]

      # Check if framebuffer has any non-zero content (only until first content seen)
      if rgba && !@has_rendered_content
        # Quick check: sample a few bytes instead of iterating all
        has_content = rgba.getbyte(0) != 0 || rgba.getbyte(rgba.bytesize / 2) != 0
        @has_rendered_content = true if has_content
      end

      if rgba && @has_rendered_content
        @rgba_buffer = rgba
      else
        # Use cached loading screen if size matches
        buffer_size = width * height * 4
        if @loading_screen_size != buffer_size
          # Generate loading screen pattern once
          rgba_arr = []
          height.times do |y|
            width.times do |x|
              if (x % 32 < 2) || (y % 32 < 2)
                rgba_arr.push(40, 40, 80, 255)  # Grid lines
              else
                rgba_arr.push(0, 0, 40, 255)    # Dark blue
              end
            end
          end
          @loading_screen = rgba_arr.pack("C*")
          @loading_screen_size = buffer_size
        end
        @rgba_buffer = @loading_screen
      end

      # Create SDL surface from RGBA data
      surface = SDL2::Surface.from_string(
        @rgba_buffer,
        width,
        height,
        32,           # depth (bits per pixel)
        width * 4,    # pitch (bytes per row)
        0x000000FF,   # R mask
        0x0000FF00,   # G mask
        0x00FF0000,   # B mask
        0xFF000000    # A mask
      )

      # Create texture from surface
      @texture&.destroy
      @texture = @renderer.create_texture_from(surface)
      surface.destroy

      # Render (stretch to window size)
      @renderer.copy(@texture, nil, nil)
      @renderer.present

      # Update FPS counter
      @frame_count += 1
      @total_frames = (@total_frames || 0) + 1
      now = Time.now
      elapsed = now - @last_fps_time
      if elapsed >= 1.0
        @fps = (@frame_count / elapsed).round(1)
        status = has_content ? "RENDERING" : "Loading..."
        @window.title = "PSX-Ruby - #{@fps} FPS - Frame #{@total_frames} - #{status}"
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

    # Read-and-clear save/load state requests. The emulator loop polls
    # these once per frame and, if true, takes the action with the
    # emulation mutex held.
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

    # Show a transient banner in the window title for save/load feedback.
    # Stays for ~2s before the FPS counter overwrites it again.
    def flash_status(msg)
      @window.title = "PSX-Ruby - #{msg}"
    end

    def controller_state
      @controller_state
    end

    def close
      @texture&.destroy
      @renderer.destroy
      @window.destroy
    end

    private

    # PS1 controller button bits
    BUTTON_SELECT   = 0
    BUTTON_L3       = 1
    BUTTON_R3       = 2
    BUTTON_START    = 3
    BUTTON_UP       = 4
    BUTTON_RIGHT    = 5
    BUTTON_DOWN     = 6
    BUTTON_LEFT     = 7
    BUTTON_L2       = 8
    BUTTON_R2       = 9
    BUTTON_L1       = 10
    BUTTON_R1       = 11
    BUTTON_TRIANGLE = 12
    BUTTON_CIRCLE   = 13
    BUTTON_CROSS    = 14
    BUTTON_SQUARE   = 15

    # Keyboard to controller mapping
    KEY_MAP = {
      SDL2::Key::Scan::UP => BUTTON_UP,
      SDL2::Key::Scan::DOWN => BUTTON_DOWN,
      SDL2::Key::Scan::LEFT => BUTTON_LEFT,
      SDL2::Key::Scan::RIGHT => BUTTON_RIGHT,
      SDL2::Key::Scan::Z => BUTTON_CROSS,
      SDL2::Key::Scan::X => BUTTON_CIRCLE,
      SDL2::Key::Scan::A => BUTTON_SQUARE,
      SDL2::Key::Scan::S => BUTTON_TRIANGLE,
      SDL2::Key::Scan::RETURN => BUTTON_START,
      SDL2::Key::Scan::SPACE => BUTTON_SELECT,
      SDL2::Key::Scan::Q => BUTTON_L1,
      SDL2::Key::Scan::W => BUTTON_R1,
      SDL2::Key::Scan::E => BUTTON_L2,
      SDL2::Key::Scan::R => BUTTON_R2
    }.freeze

    def handle_key(scancode, pressed)
      # Handle quit on Escape
      if scancode == SDL2::Key::Scan::ESCAPE && pressed
        @quit_requested = true
        return
      end

      # F5 = save state, F6 = state+screenshot, F8 = load state. Set on key-down only; the
      # emulator loop reads + clears the flag once per frame.
      if pressed
        if scancode == SDL2::Key::Scan::F5
          @save_state_requested = true
          return
        elsif scancode == SDL2::Key::Scan::F6
          @debug_snapshot_requested = true
          return
        elsif scancode == SDL2::Key::Scan::F8
          @load_state_requested = true
          return
        end
      end

      button = KEY_MAP[scancode]
      return unless button

      if pressed
        @controller_state &= ~(1 << button)  # Active low
      else
        @controller_state |= (1 << button)
      end
    end
  end
end
