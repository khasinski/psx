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

      # Performance tracking
      @frame_count = 0
      @last_fps_time = Time.now
      @fps = 0

      # Cache texture reference
      @texture = nil
    end

    def update(framebuffer)
      # Convert RGB array to 32-bit RGBA for SDL
      width = framebuffer[:width]
      height = framebuffer[:height]
      src = framebuffer[:pixels]

      # Check if framebuffer has any content
      has_content = src.any? { |p| p && p != 0 }

      # Build RGBA pixel data using pack (faster and encoding-safe)
      rgba_arr = []
      i = 0
      num_pixels = width * height

      if has_content
        # Use actual framebuffer
        num_pixels.times do
          rgba_arr << (src[i] || 0)
          rgba_arr << (src[i + 1] || 0)
          rgba_arr << (src[i + 2] || 0)
          rgba_arr << 255  # Alpha
          i += 3
        end
      else
        # Show blue screen with "loading" pattern while BIOS initializes
        height.times do |y|
          width.times do |x|
            # Dark blue background with lighter grid
            if (x % 32 < 2) || (y % 32 < 2)
              rgba_arr << 40 << 40 << 80 << 255  # Grid lines
            else
              rgba_arr << 0 << 0 << 40 << 255    # Dark blue
            end
          end
        end
      end

      rgba = rgba_arr.pack("C*")

      # Create SDL surface from RGBA data
      surface = SDL2::Surface.from_string(
        rgba,
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

    def controller_state
      @controller_state
    end

    def close
      @texture&.destroy
      @renderer.destroy
      @window.destroy
      SDL2.quit
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
