# Real-Time Window Rendering Plan for PSX-Ruby

## Current State

- Emulator runs at ~8.4% of real PS1 speed with YJIT (2.86 MHz vs 33.8688 MHz)
- GPU renders to a 1024x512 VRAM buffer (RGB555 format)
- Framebuffer output is 320x240 RGB24
- Currently outputs to PPM files for debugging

## Goal

Display emulator output in a real-time window at 60fps (or as fast as emulation allows).

## Recommended Approach: SDL2 via ruby-sdl2

### Why SDL2?

1. **Performance**: Direct hardware-accelerated texture streaming
2. **Cross-platform**: Works on macOS, Linux, Windows
3. **Low latency**: Minimal overhead for pixel buffer updates
4. **Input support**: Built-in gamepad/keyboard handling
5. **Audio support**: For future SPU implementation

### Installation

```bash
# macOS
brew install sdl2
gem install ruby-sdl2

# Linux
apt-get install libsdl2-dev
gem install ruby-sdl2

# Windows
# Download SDL2.dll and place in project directory
gem install ruby-sdl2
```

## Implementation Plan

### Phase 1: Basic Window Display

Create a new `Display` class that handles window creation and rendering:

```ruby
# lib/psx/display.rb
require 'sdl2'

module PSX
  class Display
    WIDTH = 320
    HEIGHT = 240
    SCALE = 2  # 640x480 window

    def initialize
      SDL2.init(SDL2::INIT_VIDEO)
      @window = SDL2::Window.create(
        "PSX-Ruby",
        SDL2::Window::POS_CENTERED,
        SDL2::Window::POS_CENTERED,
        WIDTH * SCALE,
        HEIGHT * SCALE,
        SDL2::Window::Flags::SHOWN
      )
      @renderer = @window.create_renderer(-1, SDL2::Renderer::Flags::ACCELERATED)
      @texture = @renderer.create_texture(
        SDL2::PixelFormat::RGB24,
        SDL2::Texture::ACCESS_STREAMING,
        WIDTH, HEIGHT
      )
    end

    def update(framebuffer)
      @texture.update(nil, framebuffer[:pixels].pack("C*"), WIDTH * 3)
      @renderer.copy(@texture)
      @renderer.present
    end

    def poll_events
      while event = SDL2::Event.poll
        case event
        when SDL2::Event::Quit
          return :quit
        when SDL2::Event::KeyDown
          handle_key(event.scancode, true)
        when SDL2::Event::KeyUp
          handle_key(event.scancode, false)
        end
      end
      nil
    end

    def close
      @texture.destroy
      @renderer.destroy
      @window.destroy
      SDL2.quit
    end

    private

    def handle_key(scancode, pressed)
      # Map keyboard to PS1 controller
      # Arrow keys -> D-pad
      # Z/X -> Cross/Circle
      # A/S -> Square/Triangle
      # Enter -> Start
      # Space -> Select
      # Q/W -> L1/R1
    end
  end
end
```

### Phase 2: Main Loop Integration

Modify `Emulator` to use the display:

```ruby
# In lib/psx.rb
def run_with_display
  display = Display.new
  frame_time = 1.0 / 60  # Target 60fps

  loop do
    frame_start = Time.now

    # Run one frame of emulation
    run(steps: CYCLES_PER_FRAME)
    @interrupts.request(Interrupts::IRQ_VBLANK)
    @gpu.vblank

    # Update display
    display.update(@gpu.framebuffer)

    # Handle input
    break if display.poll_events == :quit

    # Frame timing (if running faster than real-time)
    elapsed = Time.now - frame_start
    sleep(frame_time - elapsed) if elapsed < frame_time
  end

  display.close
end
```

### Phase 3: Performance Optimization

1. **Double Buffering**: Swap between two textures
2. **Dirty Rectangle**: Only update changed regions
3. **Thread Separation**: Run emulation and rendering in separate threads
4. **Frame Skipping**: Skip frames if emulation can't keep up

```ruby
# Frame skipping example
def run_with_frameskip
  target_fps = 60
  frame_budget = 1.0 / target_fps
  frames_to_skip = 0

  loop do
    frame_start = Time.now

    # Run emulation
    run(steps: CYCLES_PER_FRAME)
    @interrupts.request(Interrupts::IRQ_VBLANK)
    @gpu.vblank

    # Only render if not skipping
    if frames_to_skip == 0
      display.update(@gpu.framebuffer)
    else
      frames_to_skip -= 1
    end

    elapsed = Time.now - frame_start

    # Calculate frameskip based on performance
    if elapsed > frame_budget * 2
      frames_to_skip = [frames_to_skip + 1, 3].min  # Max skip 3 frames
    elsif elapsed < frame_budget
      frames_to_skip = [frames_to_skip - 1, 0].max
      sleep(frame_budget - elapsed)
    end
  end
end
```

### Phase 4: Input Handling

Create a controller abstraction:

```ruby
# lib/psx/controller.rb
module PSX
  class Controller
    BUTTONS = {
      select: 0, l3: 1, r3: 2, start: 3,
      up: 4, right: 5, down: 6, left: 7,
      l2: 8, r2: 9, l1: 10, r1: 11,
      triangle: 12, circle: 13, cross: 14, square: 15
    }

    def initialize
      @state = 0xFFFF  # All buttons released (active low)
    end

    def press(button)
      @state &= ~(1 << BUTTONS[button])
    end

    def release(button)
      @state |= (1 << BUTTONS[button])
    end

    def state
      @state
    end
  end
end
```

## Alternative Options

### Option 2: Gosu

Simpler API but less control over pixel updates:

```ruby
require 'gosu'

class PSXWindow < Gosu::Window
  def initialize(emulator)
    super(640, 480)
    self.caption = "PSX-Ruby"
    @emulator = emulator
  end

  def update
    @emulator.run(steps: PSX::Emulator::CYCLES_PER_FRAME / 60)
  end

  def draw
    fb = @emulator.gpu.framebuffer
    # Convert to Gosu::Image (slower)
  end
end
```

### Option 3: Ruby2D

Very simple but may have performance limitations:

```ruby
require 'ruby2d'

set width: 640, height: 480
pixels = Image.new('pixels', width: 320, height: 240)

update do
  emu.run(steps: PSX::Emulator::CYCLES_PER_FRAME / 60)
  # Update pixel buffer
end

show
```

## Performance Expectations

| Mode | Expected FPS | Notes |
|------|-------------|-------|
| No YJIT | ~5 FPS | Too slow for real-time |
| YJIT | ~8-10 FPS | Playable for turn-based games |
| YJIT + Frame Skip | ~15-20 FPS | Acceptable for most games |
| YJIT + Native extensions | ~30+ FPS | With C extension for hot paths |

## Recommended Next Steps

1. Install SDL2 and ruby-sdl2
2. Implement basic `Display` class
3. Add frame timing and VSync
4. Implement controller input mapping
5. Add audio support (when SPU is ready)
6. Consider C extension for critical paths if more speed needed

## Example Run Script

```ruby
#!/usr/bin/env ruby
# bin/psx-ruby-gui

require_relative '../lib/psx'

if ARGV.empty?
  puts "Usage: psx-ruby-gui <bios.bin> [game.bin]"
  exit 1
end

emu = PSX::Emulator.new(ARGV[0])
emu.load_game(ARGV[1]) if ARGV[1]
emu.run_with_display
```
