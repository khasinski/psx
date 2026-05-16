# PSX

[![Tests](https://img.shields.io/badge/tests-passing-brightgreen)](spec/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A work-in-progress PlayStation 1 emulator written in pure Ruby.

It boots the SCPH1001 BIOS into the **Memory Card / CD-ROM shell**, reads
`.bin`/`.cue` disc images via an emulated CD-ROM controller, and can
fast-boot a PS-EXE out of an ISO9660 filesystem. It runs a chunk of the
[JaCzekanski/ps1-tests](https://github.com/JaCzekanski/ps1-tests) suite.
There is no audio, no PGXP, and the BIOS license check isn't bypassed yet
(retail discs need `--fast-boot`), so don't expect to play full games.
Think of it as an executable spec for the PS1.

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
psx path/to/SCPH1001.BIN                          # BIOS shell only
psx path/to/SCPH1001.BIN game.cue                 # with a disc inserted
psx --fast-boot path/to/SCPH1001.BIN homebrew.bin # skip license check
```

`--fast-boot` skips the BIOS shell and license screen, reads `SYSTEM.CNF`
+ the PS-EXE straight out of the disc's ISO9660 filesystem, and jumps to
the EXE's entry point after the BIOS kernel has finished init. Required
for synthetic / homebrew discs that don't carry a Sony license image.

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

# BIOS shell only
emu = PSX::Emulator.new("SCPH1001.BIN")
emu.run(steps: 300_000_000)
emu.controller_state_proc = -> { 0xEFFF }    # press Triangle
emu.run(steps: 30_000_000)
emu.save_screenshot("menu.ppm")

# Fast-boot a PS-EXE from a CD image
emu = PSX::Emulator.new("SCPH1001.BIN", disc_path: "homebrew.cue")
emu.fast_boot_from_disc                       # loads the PS-EXE listed in SYSTEM.CNF
emu.run(steps: 50_000_000)
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
| `bin/psx-ruby`        | Headless boot of the BIOS (no SDL window).                              |
| `bin/psx-test`        | Run a PS-EXE on top of the BIOS, diff against ps1-tests reference logs. |
| `bin/psx-smoke`       | Boot the BIOS and dump PPM screenshots at intervals.                    |
| `bin/psx-trace`       | PC histogram + I_STAT/I_MASK summary at checkpoints.                    |
| `bin/psx-disasm`      | Disassemble a range of physical addresses after N cycles of boot.       |
| `bin/psx-biostrace`   | Tally A/B/C jump-table calls; dump the last N calls.                    |
| `bin/psx-puts-trace`  | Capture the kernel's debug TTY (`puts2`, `printf`, …).                  |
| `bin/psx-memwatch`    | Log reads/writes to specific addresses with the PC that did them.       |
| `bin/psx-dumpmem`     | Hex-dump a range of memory after N cycles of boot.                      |
| `bin/build-test-disc` | Wrap a PS-EXE in a minimal MODE2/2352 disc image (needs mkisofs).       |
| `bin/fetch-amidog-tests` | Download and unpack the amidog test suite into `.tests-amidog/`.     |
| `bin/fetch-redux-tests`  | Sparse-clone PCSX-Redux's `src/mips/` into `.tests-redux/`.          |
| `bin/psx-amidog-smoke`   | Boot every amidog test, check it reaches its startup banner.         |

### Running test suites

Three test corpora are wired in; all live under `.tests*/` (gitignored).

**JaCzekanski/ps1-tests** — pass/fail style, with reference `psx.log` files.

```sh
git clone https://github.com/JaCzekanski/ps1-tests.git .tests
bundle exec ruby bin/psx-test -e .tests/cpu/cop/psx.log .tests/cpu/cop/cop.exe
```

**amidog test programs** (https://psx.amidog.se) — CPU/GPU/GTE conformance
plus a few weird-edge demos. Several ship as proper MODE2/2352 `.bin`/`.cue`
discs with real Sony license sectors, so they exercise the CD-boot path.

```sh
bundle exec ruby bin/fetch-amidog-tests           # one-time download
bundle exec ruby bin/psx-amidog-smoke             # boot-and-banner check
```

**PCSX-Redux** (https://github.com/grumpycoders/pcsx-redux) — source-only.
Sparse-clones `src/mips/` (OpenBIOS, in-tree tests, demos). Building the
PS-EXEs needs a MIPS cross-toolchain — see `src/mips/README.md` inside the
clone for instructions. Useful as a reference for hardware behaviour even
without building.

```sh
bundle exec ruby bin/fetch-redux-tests
```

## Status

What works:

- MIPS R3000A CPU with delay slots, exceptions, COP0
- GTE (passes the `gte/test-all` shape, several coverage gaps)
- GPU: GP0 polygons / lines / rectangles, textured / shaded / semi-transparent
  primitives, CPU↔VRAM blits, mask bit. Software rasteriser, no PGXP.
- DMA channels for OTC, GPU (block / linked list), SPU, CD-ROM
- Interrupt controller, root counters
- CD-ROM controller backed by `.bin`/`.cue` images, with SetLoc / ReadN /
  Pause / SeekL / GetlocL / GetTN / GetTD / GetID / Init / SetMode and
  cycle-paced INT1 sector delivery
- ISO9660 reader for SYSTEM.CNF + PS-EXE extraction
- Fast-boot: skip the BIOS shell + license check, run the disc's PS-EXE directly
- SIO0 digital pad (slot 1)
- SPU stub (mirrors SPUCNT → SPUSTAT, register window read-back; no
  actual audio synthesis)
- Boots SCPH1001 into the Memory Card menu
- Bus-error on instruction fetch from forbidden regions (scratchpad,
  IRQ, MDEC, timers, JOY/SIO); fetch from DMA / SPU / GPU register
  space goes through (matches real hardware)
- 18/18 of the JaCzekanski/ps1-tests cases that have a `psx.log`
  reference and don't require a disc image (cpu/, dma/, gpu/, gte/,
  mdec/, spu/, timers/) — see `bin/_ps1tests-baseline`

What doesn't:

- No SPU audio synthesis (no sound)
- CD-ROM ps1-tests (`cdrom/disc-swap`, `cdrom/getloc`, `cdrom/timing`)
  can't run via `bin/psx-test` because no disc image is wired into
  the bare-EXE loader path
- DMA timing isn't cycle-accurate — `dma/chopping` runs but reports
  `29 CPU cycles` for every block size where real hardware sees
  thousands; structural test pass, not bit-perfect timing
- GTE op timing matches nocash per-opcode cycle counts when measured
  through Timer 2 in sysclock mode (see `spec/gte_timing_spec.rb`);
  visual verification against amidog's psxtest_gte OFFICIAL.TIMING
  column hasn't been completed

## License

MIT. See [LICENSE](LICENSE).
