# Changelog

## Unreleased

### Game compatibility

- Boots Rage Racer through the menu and into FMV.
- Fix BFRD-toggle bug so the BIOS shell boots discs end-to-end on both
  SCPH1001 and SCPH7502 with no patches.

### Disc / CD-ROM

- New `PSX::Disc` loader for `.bin`/`.cue` images (single- or multi-track,
  MODE1/MODE2/AUDIO). Per-FILE `lba_length` for multi-bin cues.
- New `PSX::ISO9660` reader for finding files in the disc's root directory.
- `PSX::CDROM` rewritten as a real state machine: SetLoc, ReadN/ReadS,
  Pause, SeekL/P, GetlocL/P, GetTN, GetTD, GetID against a real disc,
  Init, SetMode, ReadTOC. Cycle-paced INT1 sector delivery.
- `whole_sector` mode (SetMode bit 5) implemented end-to-end.
- CDDA audio streaming through SDL2 queued-audio output.
- DMA channel 3 (CDROM) now drains the data FIFO into RAM.
- `Emulator.new` takes an optional `disc_path:` argument.
- `Emulator#fast_boot_from_disc`: skip the BIOS shell + license check,
  read SYSTEM.CNF + PSX.EXE from the disc, jump to entry. Exposed via the
  CLI as `psx --fast-boot <bios> <disc>`. Works on retail discs.
- `bin/build-test-disc` dev tool wraps a PS-EXE in a minimal MODE2/2352
  CD image for end-to-end testing.

### MDEC

- New MDEC implementation: register surface, quant/IDCT tables, DMA0/1
  ingress + egress, full RLC + dequant + IDCT + YCbCr decoder.

### Save states

- F5 / F8 save and load from the SDL window, plus a bench harness and a
  round-trip test.

### GPU

- Semi-transparency blending for untextured triangles, rects, textured
  rects, and textured triangles.
- Off-by-one fix in `polygon_word_count` for textured-gouraud polys.
- Rasteriser rewrites: per-pixel color/UV hash lookups hoisted out of
  inner loops; rect, triangle, textured-rect, and textured-triangle
  paths inlined directly into VRAM; `Array#fill` for opaque flat
  scanlines; while-loop scanlines in the triangle rasteriser.

### GTE

- Halve `unr_divide` result to match the canonical `N = H / (2 * SZ3)`
  form.
- Per-opcode cycle counts.
- Hot-path allocation cleanup: no more 64-bit bignum allocations in
  `mac_set` / `unr_divide`; matrix rows and flag-lookup arrays cached;
  `mac_set` specialised per channel (`mac_set1/2/3`).

### CPU / memory

- R3000 overflow and alignment exceptions wired up.
- Trap instruction fetch from forbidden bus regions.
- Symmetric upper-RAM mirror to match real hardware (replaces earlier
  asymmetric attempt).
- RAM now stored as a word array, with RAM/BIOS lookups inlined into
  `read32`/`write32`.
- Step returns its cycle count; interrupt check lifted into the run loop;
  hot opcode bodies, `fetch32`, `set_reg`, `sign_extend16`, and the RAM
  fast path inlined into `step` / `op_lw` / `op_sw`.
- Nested-loop `run_fast` for a tighter inner loop.
- Timer ticks batched at 64-cycle granularity (~26% speedup).

### Timers / DMA / interrupts

- Honor Timer 0/1/2 clock-source mode bits.
- Accumulate sub-cycle ticks for HBLANK-sourced Timer 0/1.
- Suspend the GPU DMA channel on runaway chains instead of faking
  completion; bound GPU linked-list DMA walks to prevent self-loop hangs.

### BIOS / boot

- BIOS shell past the license check and onto the bootstrap loader.
- Format BIOS printf args in the TTY intercept.
- Scaffolding for fast-boot patches (no useful patches found yet).

### Conformance and tooling

- Wired in the amidog + PCSX-Redux test corpora; ps1-tests baseline +
  bench + profiler scripts; fuzzy-matched reference text for
  marker-less ps1-tests.
- `psx-test --disc` so cdrom tests can run with a disc inserted.
- Dev scripts: `_psx-bootmap`, `_psx-exe-display`, `_psx-makestate`,
  `ridge-boot` with optional CD-ROM command trace and
  `PSX_START_AT_CYCLES` tap.

## 0.1.0 — 2026-05-15

Initial release.

- MIPS R3000A CPU with proper delay-slot / exception EPC handling.
- COP0 and GTE (coprocessor 2) coverage sufficient for the BIOS boot path.
- Software-rasteriser GPU covering most GP0/GP1 commands, textures (4/8/15
  bit + CLUT), semi-transparency, mask bit.
- DMA channels: OTC, GPU (block & linked-list), SPU, CDROM.
- Interrupt controller, root counters, CD-ROM stub, SPU stub, SIO0 digital
  pad (slot 1).
- Boots the SCPH1001 BIOS into the Memory Card / CD-ROM shell menu.
- `psx` SDL-backed CLI front-end.
