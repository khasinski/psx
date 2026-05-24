# MDEC Implementation — Scoping

## What MDEC does

The MDEC (Motion DECoder) is a fixed-function JPEG-style decoder. It accepts a
stream of run-length-encoded DCT coefficients, performs inverse quantisation +
inverse DCT, optionally converts YUV-420 macroblocks to RGB, and emits decoded
pixel data through DMA. The PSX uses it for two things in practice:

1. **Full-motion video (FMV)** — every retail game with an intro / cutscene
   funnels MJPEG-compressed frames through MDEC. The .STR file format
   interleaves video sectors (which feed MDEC) with CD-XA audio sectors.
2. **Static image decompression** — some games store sprite atlases or
   textures as MDEC-compressed blocks and decode them at load time.

For us, the relevant impact is that **every retail game from ~1996 onward
has an intro that requires MDEC**. Without it, the game's loader either
spins forever waiting for the first frame (Rage Racer, today) or skips the
intro entirely and proceeds — depends on the game.

## Hardware surface area

Two 32-bit registers at `0x1F801820` (command/data) and `0x1F801824`
(status/control), plus two DMA channels:

| What | Address | Role |
| --- | --- | --- |
| MDEC0 (write) | `0x1F801820` | Command + RLC data stream input |
| MDEC0 (read)  | `0x1F801820` | Decoded macroblock output |
| MDEC1 (write) | `0x1F801824` | Control (reset, enable DMA) |
| MDEC1 (read)  | `0x1F801824` | Status (busy, FIFO state, output mode) |
| DMA channel 0 | RAM → MDEC0 | Stream RLE coefficient data |
| DMA channel 1 | MDEC0 → RAM | Pull decoded pixels |

Three commands enter through MDEC0:

- **Command 1** — Decode N macroblocks (bits 25..16 hold the parameter count
  for the actual decode; data words follow)
- **Command 2** — Load colour and luminance quantisation tables (64 + 64 bytes)
- **Command 3** — Load IDCT scaling table (64 × s16)

Output modes set by command 1 bits:

- 4-bit indexed (1 macroblock = 8×8 luma → 4 bits/pixel via dither)
- 8-bit indexed (8×8 luma → 8 bits)
- 15-bit RGB (Y/Cr/Cb → RGB555, 16×16 macroblock)
- 24-bit RGB (Y/Cr/Cb → RGB888, 16×16 macroblock — what FMV uses)

## What we have today

Effectively nothing. `lib/psx/memory.rb` doesn't even route 0x1F801820/24
to a handler — they fall through the case-when chains and return 0 on reads,
silently drop on writes. DMA channels 0 + 1 are declared as constants
(`MDEC_IN = 0, MDEC_OUT = 1`) but `transfer_gpu` / `transfer_spu` / etc.
have no equivalent for them.

The relevant ps1-tests are already in `.tests/mdec/`:

| Test | What it exercises | Reference output |
| --- | --- | --- |
| `mdec/4bit` | Single 8×8 macroblock, 4-bit indexed mode | `vram.png` |
| `mdec/8bit` | Single 8×8, 8-bit indexed | `vram.png` |
| `mdec/frame` | One 320×240 frame, 15-bit RGB | `vram-15bit.png` |
| `mdec/movie` | Bad Apple .STR stream, both 15-bit and 24-bit | `vram-15bit.png` |
| `mdec/step-by-step-log` | Logs every register state transition | `psx.log` |

These give us a clean test ladder — each phase below lines up with passing
one more of these.

## Implementation phases

### Phase 1 — Stub + register surface (1-2 hours)

Goal: get reads and writes hitting an `MDEC` class without breaking
anything. No actual decoding.

- New `lib/psx/mdec.rb` with `read32 / write32` matching the 0x1F801820 /
  0x1F801824 ABI.
- Hook into `Memory#io_read32` / `io_write32` at offset 0x820/0x824.
- Save state hooks.
- Status register returns "idle, FIFO empty, command-ready" (the bits the
  game polls to decide whether it's safe to send a new command).
- Reset (command on MDEC1) clears state.

Verifies: `mdec/step-by-step-log` should run without crashing and reach
its "Done" marker, even though the decoded output is garbage.

### Phase 2 — Quantisation / IDCT table commands + DMA0 ingress (3-4 hours)

Goal: accept command words and table-load streams correctly.

- Command-word parser: decode bits 25..16 (count) and 28..27 (mode).
- Command 2: read 64 + 64 bytes for two quant tables (luma + chroma).
- Command 3: read 64 × s16 for the IDCT scaling table.
- Command 1: read parameter words into a working buffer.
- DMA channel 0 (RAM → MDEC0): wire up `transfer_mdec_in` in `lib/psx/dma.rb`,
  parallel to `transfer_spu`. Block-transfer mode is what the test programs use.
- Status bits: command-busy, parameters-needed-N counter.

Verifies: tests can submit data without our emulator hanging. Output is
still wrong but the test logs should show our register state matching the
reference at command-acceptance boundaries.

### Phase 3 — Decoder core (1-2 days)

The actual JPEG-style decoder. Three sub-phases:

#### 3a — RLE decode
- Read 16-bit RLC pairs from the input stream.
- For each pair: (zero-run-length-skip, coefficient).
- Build 64-coefficient blocks in zig-zag order.

#### 3b — Dequantise + IDCT
- Multiply each coefficient by the matching quant-table entry and the
  global "qscale" sent in the block header.
- Run inverse DCT (8×8 fixed-point, AAN or similar). Reference implementations
  in DuckStation / pcsx-redux / mednafen. Output is signed 9-bit samples.

#### 3c — Macroblock assembly + output formatting
- For 15/24-bit modes: decode 2 chroma blocks (Cr, Cb) + 4 luma blocks per
  16×16 macroblock.
- YCbCr → RGB conversion (BT.601 coefficients).
- Pack into the requested output format (4/8/15/24 bit).
- Drop output bytes into the MDEC0 read FIFO.

Verifies: `mdec/4bit`, `mdec/8bit`, `mdec/frame` produce output that pixel-
compares against the reference VRAM dumps.

### Phase 4 — DMA1 egress + IRQ (half day)

Goal: tie output back into game's read path.

- DMA channel 1 (MDEC0 → RAM): wire up `transfer_mdec_out`.
- IRQ source: when output buffer drains and the game has set MDEC1 bit 30
  (enable-IRQ), raise DMA channel 1 completion interrupt.

Verifies: `mdec/movie` plays end to end (Bad Apple frames render to VRAM
through the full DMA chain).

### Phase 5 — Stream integration (1-2 days, partly speculative)

What's needed to make real FMV games work, beyond just MDEC-correctness:

- CD-XA sector filtering: the game's reader checks sub-header
  file/channel/submode bytes to decide whether a sector is video or audio.
  We already serve the sub-header (whole_sector mode fix from today), so
  the filter side should work; we just need to make sure our pacing matches
  the game's expected sector-rate.
- SPU streaming: audio frames need ack via SPU IRQ. Without this, games
  that synchronise video and audio (i.e. all FMV games) stall. Out of
  scope for the MDEC project — separate scoping.

Verifies: Rage Racer intro displays (silent, since SPU stream isn't done).

## Effort

| Phase | Optimistic | Realistic |
| --- | --- | --- |
| 1 (stub) | 1h | 2h |
| 2 (ingress) | 3h | 6h |
| 3 (decoder) | 1 day | 2-3 days |
| 4 (egress + IRQ) | 4h | 1 day |
| 5 (integration) | 1 day | 2-3 days |
| **Total** | **~3 days** | **~1 week** |

Phase 3 is the bulk of the work. The IDCT itself isn't novel — every JPEG
decoder has it, and there are public-domain references — but the PSX has
specific signed-9-bit clamping, fixed-point scaling, and zig-zag order
quirks that take time to get right against the reference outputs.

## Testing strategy

Each phase has a clear pass gate from ps1-tests. I'd write a
`bin/_psx-mdec-conformance` runner that boots each test EXE, runs it for
a fixed cycle budget, and pixel-compares the resulting VRAM dump against
the reference `vram.png`. That gives us:

- A green/red signal per phase
- Regression coverage as we move forward
- A natural way to ship partial progress (Phase 3a/3b/3c each unlock specific
  tests)

This is the same shape that worked well for the BIOS-boot perf session
(profile → bench → assert) — empirical, gated, no faith required.

## Risks

- **IDCT precision**: ps1-tests use exact bit comparisons against the
  reference VRAM. Off-by-one rounding in the IDCT will fail tests even
  if the output looks visually correct. Likely several iterations to
  match.
- **Pipelining**: real MDEC has a small FIFO and the game can read output
  while still feeding input. Most test EXEs do the simple "command, then
  drain" pattern, so we can ship a simpler model first and only worry
  about pipelining if a real game needs it.
- **24-bit unpacking**: the output is packed 24 bits per pixel as 32-bit
  words containing 4/3 pixels per word, with a specific byte order. Easy
  to get wrong; pixel-compare will catch it.
