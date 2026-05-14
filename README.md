# PSX

[![Tests](https://img.shields.io/badge/tests-passing-brightgreen)](spec/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A work-in-progress PlayStation 1 emulator written in pure Ruby.

It boots the SCPH1001 BIOS into the **Memory Card / CD-ROM shell** and can
run a chunk of the [JaCzekanski/ps1-tests](https://github.com/JaCzekanski/ps1-tests)
suite. There is no audio, the CD-ROM is a stub (no disc image loading yet),
and the GPU is a software rasteriser with rough texture sampling — so don't
expect to play games. Think of it as an executable spec for the PS1.

![Memory Card menu rendered by the BIOS](docs/shell_menu.png)

## Install

```sh
gem install psx
```

You will also need SDL2 on your system (the gem depends on `ruby-sdl2`):

- macOS: `brew install sdl2`
- Debian / Ubuntu: `sudo apt install libsdl2-dev`
- Arch: `sudo pacman -S sdl2`

## Usage

You must supply your own BIOS ROM (typically `SCPH1001.BIN`, 512 KB). PSX
does not ship one — BIOS images are copyrighted.

```sh
psx path/to/SCPH1001.BIN
```

Run `psx --help` for the option list. Keyboard controls (slot 1 digital pad):

| Key            | Button   |
| -------------- | -------- |
| Arrow keys     | D-pad    |
| Z              | Cross    |
| X              | Circle   |
| A              | Square   |
| S              | Triangle |
| Enter          | Start    |
| Space          | Select   |
| Q / W          | L1 / R1  |
| E / R          | L2 / R2  |
| Escape         | Quit     |

The BIOS shell idles on the Sony logo until you press Triangle, which opens
the Memory Card / CD-ROM menu.

## Programmatic use

```ruby
require "psx"

emu = PSX::Emulator.new("SCPH1001.BIN")
emu.run(steps: 300_000_000)            # boot to shell
emu.controller_state_proc = -> { 0xEFFF }   # press Triangle
emu.run(steps: 30_000_000)
emu.save_screenshot("menu.ppm")
```

The emulator exposes the major components individually: `emu.cpu`,
`emu.memory`, `emu.gpu`, `emu.dma`, `emu.cdrom`, `emu.sio0`, `emu.interrupts`,
`emu.timers`.

## Development

```sh
git clone https://github.com/khasinski/psx
cd psx
bundle install
bundle exec rake test
```

The `bin/` directory contains development tools that are *not* shipped with
the gem:

| Script            | Purpose                                                                 |
| ----------------- | ----------------------------------------------------------------------- |
| `bin/psx-ruby`    | Headless boot of the BIOS (no SDL window).                              |
| `bin/psx-test`    | Run a PS-EXE on top of the BIOS, diff against ps1-tests reference logs. |
| `bin/psx-smoke`   | Boot the BIOS and dump PPM screenshots at intervals.                    |
| `bin/psx-trace`   | PC histogram + I_STAT/I_MASK summary at checkpoints.                    |
| `bin/psx-disasm`  | Disassemble a range of physical addresses after N cycles of boot.       |
| `bin/psx-biostrace` | Tally A/B/C jump-table calls; dump the last N calls.                   |
| `bin/psx-puts-trace` | Capture the kernel's debug TTY (`puts2`, `printf`, …).                |
| `bin/psx-memwatch`| Log reads/writes to specific addresses with the PC that did them.       |
| `bin/psx-dumpmem` | Hex-dump a range of memory after N cycles of boot.                      |

### Running ps1-tests

The `bin/psx-test` runner expects a local checkout of
[JaCzekanski/ps1-tests](https://github.com/JaCzekanski/ps1-tests):

```sh
git clone https://github.com/JaCzekanski/ps1-tests.git .tests
bundle exec ruby bin/psx-test -e .tests/cpu/cop/psx.log .tests/cpu/cop/cop.exe
```

## Status

What works:

- MIPS R3000A CPU with delay slots, exceptions, COP0
- GTE (passes the `gte/test-all` shape, several coverage gaps)
- GPU: GP0 polygons / lines / rectangles, textured / shaded / semi-transparent
  primitives, CPU↔VRAM blits, mask bit. Software rasteriser, no PGXP.
- DMA channels for OTC, GPU (block / linked list), SPU (stub), CDROM (stub)
- Interrupt controller, root counters
- CD-ROM stub (responds to BIOS probe; no disc image support)
- SIO0 digital pad (slot 1)
- SPU stub (mirrors SPUCNT → SPUSTAT; no actual audio synthesis)
- Boots SCPH1001 into the Memory Card menu

What doesn't:

- No CD-ROM image loading — can't boot real games
- No SPU audio synthesis (no sound)
- Several ps1-tests fail (CD-ROM timing, code-in-IO bus errors)
- Texture sampling has visible glitches on the shell UI

## License

MIT. See [LICENSE](LICENSE).
