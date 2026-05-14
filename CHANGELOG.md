# Changelog

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
