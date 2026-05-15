# Changelog

## Unreleased

- New `PSX::Disc` loader for `.bin`/`.cue` images (single- or multi-track,
  MODE1/MODE2/AUDIO).
- New `PSX::ISO9660` reader for finding files in the disc's root directory.
- `PSX::CDROM` rewritten as a real state machine: SetLoc, ReadN/ReadS,
  Pause, SeekL/P, GetlocL/P, GetTN, GetTD, GetID against a real disc,
  Init, SetMode, ReadTOC. Cycle-paced INT1 sector delivery.
- DMA channel 3 (CDROM) now drains the data FIFO into RAM.
- `Emulator.new` takes an optional `disc_path:` argument.
- `Emulator#fast_boot_from_disc`: skip the BIOS shell + license check,
  read SYSTEM.CNF + PSX.EXE from the disc, jump to entry. Exposed via the
  CLI as `psx --fast-boot <bios> <disc>`.
- `bin/build-test-disc` dev tool wraps a PS-EXE in a minimal MODE2/2352
  CD image for end-to-end testing.

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
