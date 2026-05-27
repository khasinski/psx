# Current state

Snapshot of where the emulator is and what we just spent time on.

## Latest continuation

2026-05-27 fifth update:

- Fixed the Rage Europe intro FMV presentation path. The main issue after the
  title/menu breakthrough was not only MDEC colour math: Rage decodes 24-bit
  MDEC frames and uploads them to VRAM in 16-pixel-wide strips. The previous
  scoped DMA IRQ shim acknowledged I_STAT/DICR in a way that dropped nested
  channel-1 completions raised inside the MDEC-out callback, so only the first
  strip reached VRAM.
- The DMA shim now acknowledges the original channel-1 DICR flag before
  invoking callback `0x8001EBC8`, and re-requests IRQ_DMA if DICR still has the
  master flag after the outer I_STAT ack. That lets Rage chain all MDEC-out
  strip callbacks for each frame.
- Added GPU 24-bit display extraction. Rage sets GP1 display mode `0x19`
  (`320x240`, PAL, 24-bit colour) for the FMV; `GPU#framebuffer` now reads
  24-bit BGR pixels packed across 16-bit VRAM words instead of always treating
  VRAM as RGB555.
- Improved MDEC command-1 output:
  - 8-bit unsigned output now applies the +128 bias.
  - 24-bit output is packed as B, G, R bytes for GPU 24-bit display.
  - RLE dequant/IDCT now uses the loaded hardware IDCT table and zig-zag
    quant indexing rather than the earlier rough floating IDCT.
- Verification:
  - `mise exec -- ruby -Ilib -Ispec spec/gpu_spec.rb` passes:
    15 runs, 37 assertions.
  - `mise exec -- ruby -Ilib -Ispec spec/dma_spec.rb` passes:
    16 runs, 44 assertions.
  - `mise exec -- ruby -Ilib -Ispec spec/interrupts_spec.rb` passes:
    14 runs, 30 assertions.
  - `mise exec -- rake test` passes:
    225 runs, 545 assertions.
- Rage Europe FMV evidence:
  - `conformance-shots/rage-eu-strip-rerequest/ridge-008.png` shows a coherent
    full-frame car shot (`76`) instead of the old single left strip / false
    colour output.
  - `conformance-shots/rage-eu-strip-rerequest/ridge-012.png` shows a coherent
    countdown shot.
  - A 3.0B-cycle continuation in
    `conformance-shots/rage-eu-fmv-correct-menu` stays in the now-visible intro
    FMV longer than the earlier broken playback and shows readable animated
    text at `ridge-012.png`.
- Remaining caveat: MDEC is much closer but not fully conformance-clean. The
  bundled `.tests/mdec/8bit` hexdump is within a few low-bit differences after
  the IDCT/dequant change, while the generic `frame-15bit/24bit` conformance
  images still show block/order issues. That is separate follow-up MDEC
  accuracy work; Rage's intro FMV presentation is now visibly coherent.

2026-05-27 fourth update:

- Added a scoped Rage Europe MDEC-out DMA completion path while the intro
  whole-sector stream is active. The game registers channel 1's callback at
  `0x8009A4FC = 0x8001EBC8`; the low-vector shim now invokes only that callback
  when DICR has the channel-1 flag, then acknowledges the DICR flags. This is
  intentionally narrower than the rejected generic DMA dispatcher.
- Added a scoped VBlank callback invocation from the installed callback table
  (`0x80099434`) for the same low-vector fallback path. This keeps the shim
  closer to the BIOS callback flow without re-enabling broad DMA dispatch.
- Added MDEC-out DMA backpressure: channel 1 now remains armed when the MDEC
  output FIFO is empty and is retried from `DMA#tick_cycles` once MDEC has
  output. Regression coverage in `spec/dma_spec.rb` verifies this.
- Verification:
  - `mise exec -- ruby -Ilib -Ispec spec/interrupts_spec.rb` passes:
    14 runs, 30 assertions.
  - `mise exec -- ruby -Ilib -Ispec spec/dma_spec.rb` passes:
    16 runs, 44 assertions.
  - `mise exec -- rake test` passes:
    224 runs, 539 assertions.
- Rage Europe smoke results:
  - `conformance-shots/rage-eu-mdec-dma` reaches visible decoded FMV frames
    instead of black. At 1.2B cycles screenshots `ridge-008`/`ridge-012` are
    nonzero (`nz≈167k`, `max=248`).
  - `conformance-shots/rage-eu-long-video`, 2.5B cycles with Start toggling,
    reaches the title screen. `ridge-010.png` shows the Rage Racer logo and
    `PRESS START`.
  - `conformance-shots/rage-eu-title-dense`, dense 50M-cycle captures from
    2.2B onward with Start held from 2.45B to 2.95B, proves the target state:
    `rage-2650000000.png` and `rage-2700000000.png` show the selectable main
    menu with `GRAND PRIX`, `TIME ATTACK`, `SAVE&LOAD`, and `OPTION`.
  - `conformance-shots/rage-eu-title-start`, 3.0B cycles, shows the flow after
    menu input/transition: `ridge-012.png` displays `PRISE GP` /
    `"OVER PASS CITY"`.
  - `conformance-shots/rage-eu-menu-run`, 4.0B cycles, continues into the next
    game sequence but did not capture a selectable main menu in that window.
- Important observations:
  - Before the MDEC callback, MDEC output accumulated (`@output_words_remaining`
    around `43776`) while display stayed disabled. Running callback
    `0x8001EBC8` lets the game set up/present decoded frames.
  - The image is visible but MDEC colour/edge quality is rough; this is now an
    accuracy issue rather than a boot blocker.
  - Pad polling stops during the initial FMV and resumes after the title screen
    appears. A probe that presses Start from 2.4B cycles onward saw controller
    polls resume between 2.5B and 2.75B (`calls` rose from 666 to 1410, all new
    polls seeing Start pressed), then continued into the `0x8006DDxx`/
    `0x8006DExx` path.
- Goal evidence: Rage Racer Europe now boots through intro FMV to the title
  screen and reaches the selectable main menu. The menu appears around 2.65B
  cycles in `conformance-shots/rage-eu-title-dense/rage-2650000000.png`.

2026-05-27 third update:

- Replaced the temporary Rage Europe intro CD IRQ "status-only" shim with a
  scoped execution of the game's installed CD-ROM interrupt callback
  (`0x8006C17C`, table entry at `0x8009943C`) when the low exception vector is
  unusable during whole-sector streaming from LBA 304.
- The wrapper runs the callback with a return sentinel and restores the
  interrupted CPU context afterward: PC/next PC/branch state, load delay,
  GPRs, HI/LO, COP0 registers, and cache-isolated state. This models the BIOS
  dispatcher enough for the callback's memory/device side effects to happen
  without leaking callback register state into foreground game code.
- Verification:
  - `mise exec -- ruby -Ilib -Ispec spec/interrupts_spec.rb` passes:
    14 runs, 30 assertions.
  - `mise exec -- rake test` passes:
    223 runs, 534 assertions.
- Rage Europe smoke with this real-CD-callback path:
  `PSX_DISC="$HOME/Downloads/Rage Racer (Europe)/Rage Racer (Europe)/Rage Racer (Europe).cue" PSX_CYCLES=800_000_000 PSX_CHUNK=100_000_000 PSX_START_AT_CYCLES=250_000_000 PSX_OUT=conformance-shots/rage-eu-real-callback mise exec -- ruby bin/_ridge-boot --fast-boot`
  runs through 800M cycles without returning to the decoder overflow. It is
  still black; screenshots `ridge-004.ppm` and `ridge-008.ppm` have `nz=0`.
- Compared with the previous shallow shim, the real CD callback does real
  FIFO work. An isolated callback probe moved `data_pos` from 0 to 44 and
  cleared CD IRQ state in 807 CPU steps, instead of only copying the stat byte
  to `0x8009BAF0/BAF8`.
- At 400M with the stable real-CD-only path, the stream queue at
  `0x800FF2E0` is populated but entries sit in state `3`:
  `q00..q05 = 0003 8001 0006000x 00000001 0000087C 00C00140`.
  The foreground helper at `0x8006D0EC` only returns queue pointers for state
  `1` or `2`, so it keeps returning through `0x8006D1A8`.
- Tried and rejected in this pass: dispatching every pending installed
  callback bit (VBlank/CD/DMA) from the scoped low-vector path. That re-enabled
  the old failure by 400M (`EPC=80064760`, pending CD IRQ at LBA 446,
  `SR=40000400`, `CAUSE=00000430`). The likely issue is that the ad-hoc
  dispatcher is still not equivalent to the BIOS IRQ path for nested DMA/VBlank
  work. Do not reapply broad callback dispatch without modeling the BIOS
  dispatcher/exception return more faithfully.
- Next target: explain who transitions the Rage stream queue entries from
  state `3` to state `1`/`2`. The likely candidates are the DMA/MDEC completion
  path or a game-side postprocess callback; instrument writes to
  `0x800FF2E0..0x800FF3BF`, DICR (`0x1F8010F4`), and callbacks under
  `0x8009A4F8..` before changing behavior again.
- Follow-up trace from the next pass:
  - Rage registers `0x8006CE78` at `0x8009A504`, which is the DMA channel 3
    callback used by the generic DMA IRQ dispatcher (`0x8006E87C`).
  - `0x8006CE78` is the routine that changes the current stream queue entry
    from state `3` to state `2`.
  - The CD callback starts two CD-ROM DMA transfers for wanted sectors:
    an 8-word header/STR-prefix transfer and a `0x1F8` word payload transfer.
    After the payload DMA, code at `0x8006DAEC` writes state `3` and advances
    `0x801E6C74`.
  - Naively delivering the channel-3 DMA callback from the scoped interrupt
    shim does transition the queue, but it quickly reintroduces stream decoder
    corruption: by 240M-400M the decoder writes through the `0x802xxxxx` RAM
    mirror over code around `0x80064740`, then traps at `EPC=80064760`.
    Guarding the DMA callback to only run when the current entry is state `3`
    changes the signature but still regresses by 400M (`PC=80000080`,
    `CAUSE=B000042C`, corrupted low vector).
  - A 2048-byte whole-sector backpressure threshold was also tried because the
    observed Rage DMA pattern consumes 8 + 0x1F8 words. It did not fix the
    overflow and was reverted to the previous 2060 threshold.
  - Acknowledge-only-CD semantics were also tried and rejected. Leaving the DMA
    bit pending while the low vector is corrupted sends the CPU back through
    `0x80000080` by 400M (`CAUSE=B000042C`). The current stable shim still
    acknowledges the full pending mask after running the real CD callback.
  - The current tree intentionally keeps only the stable real-CD-callback
    improvement; the DMA callback experiments above were not left enabled.
- Follow-up trace from the next continuation:
  - `lui 0x801F; lw -32140` in this code is `0x801E8274`, not
    `0x801F8274`. Earlier notes naming `0x801F8274` for that flag were wrong.
  - The synchronous branch at `0x8006DB0C` is disabled because
    `0x801E8274` is cleared by `0x8006CF98`; forcing it was only a probe, not
    a fix.
  - The forced immediate completion hook at `0x8006DB08 -> 0x8006CE78`
    causes the game to decode sector 0 before continuation sectors are ready.
    At the first decoder hit (`0x80064758`), only `q0` is complete and the
    source pointer is `0x800FF6EC`.
  - Completing only `q0` after all six sectors are queued also does not work:
    the decoder starts from `0x800FF6EC`, the output pointer is
    `0x800D18E6`, and the decoder end pointer is `0x820D18DE`. That huge end
    pointer comes from the decoder limit word at `0x80064554`, which is still
    `0x00FFFFFF`. Rage normally relies on the stream terminator rather than
    that limit.
  - Sector data layout looks intentional, not a simple offset bug. For LBA
    304, the decoded source begins at whole-sector offset 44. The next sector
    buffer starts 2004 bytes later; that accounts for the 12-byte frame header
    skipped only on the first sector. Sectors 306+ in the first six-sector
    group are mostly zero in the 44..2059 range, with nonzero bytes only in
    the later tail area, so the remaining corruption question is why Rage's
    software bitstream decoder does not see an end marker before it runs past
    the intended frame.
  - A bounded decoder-limit probe without queue completion did not exercise
    the decoder, so it did not prove anything useful. If revisited, combine it
    with a correct queue-completion model and check screenshots/output, not
    just PC survival.

2026-05-27 second update:

- Fixed the immediate Rage Europe whole-sector streaming stall at LBA 312.
  Rage reads a 44-byte XA/STR prefix from unwanted sectors and leaves the
  payload unread; `CDROM#unread_sector_blocks_stream?` now treats that small
  prefix as a filter read, while still applying backpressure for deeper
  partially consumed payloads.
- Added `spec/cdrom_spec.rb` coverage for the 44-byte prefix-skip case using
  a two-sector disc image.
- Verification:
  - `mise exec -- ruby -Ilib -Ispec spec/cdrom_spec.rb` passes:
    7 runs, 20 assertions.
  - `mise exec -- rake test` passes:
    222 runs, 530 assertions.
- Rage Europe smoke now advances past the old LBA 312 stall. At 150M cycles
  it reaches about LBA 404 with `data_pos=44`; by 175M it has a wanted sector
  pending at LBA 413 (`irq_flags=01`, `data_pos=0`).
- New blocker: the pending CD IRQ is not serviced because the low exception
  vector is still empty in our model. With CD data not drained, Rage's
  decoder eventually runs through stale/zero stream data, writes output past
  `0x80200000`, and mirrors back over its own code around `0x80064758`.
  The visible symptom is an arithmetic-overflow trap at `EPC=80064760` after
  the decoder instruction bytes have already been clobbered:
  `0x80064758` becomes `00000000` and `0x8006475C` becomes `00080000`.
- Important trace details for the next pass:
  - Game interrupt callback table at 150M:
    `0x80099430 = 00000001`, callbacks include `8006E75C` (VBlank),
    `8006C17C` (CD-ROM), `8006E87C` (DMA), and mask/state at
    `0x80099460 = 0000000D`.
  - Low RAM/cache trace during BIOS boot shows only zero cache-isolated writes
    to `0x00000000..0x000003FF`; no non-zero low-vector handler is currently
    captured.
  - The next real fix is not more CD backpressure. It is a proper low-vector /
    instruction-cache exception path, or a scoped BIOS interrupt dispatcher
    that preserves game registers while invoking callbacks.
- Tried and rejected this turn:
  - Caching normal low-RAM instruction fetches so the `0x80000080` handler
    survives later RAM clears. It made the low vector fetchable, but regressed
    Rage back into the loader before the intro stream: CD stayed at LBA 304
    with INT3 pending, and COP0 ended around `SR=40000400`, `CAUSE=00000400`.
  - HLEing syscall `a0=1/2` as Enter/ExitCriticalSection. A naive SR save/
    restore and a variant that forced the hardware interrupt mask both failed
    to recover the loader. Do not reapply this without modeling the BIOS
    exception return path more accurately.
  - Useful trace from that rejected path: the low vector bytes are
    `3C1A0000 275A0C80 03400008 00000000`, i.e. jump to `0x80000C80`.
    Syscall wrappers at `0x80063210`/`0x80063220` execute `syscall` with
    `a0=1/2`; unresolved `CAUSE=00000420` seen earlier was syscall plus
    pending hardware IRQ, not an address error.

2026-05-27 update:

- Added a minimal cache-isolated instruction fetch model. Cache-isolated
  32-bit RAM writes now populate an instruction-cache map without changing
  RAM data, and CPU fetch uses that cached word as a fallback when backing
  RAM is zero. This preserves the BIOS/game low exception handler after the
  RAM copy is cleared, without overriding normal PS-EXE RAM code.
- Regression added in `spec/memory_spec.rb`: isolated writes are not visible
  through data reads, but are visible through instruction fetch.
- Focused CPU/memory/interrupt tests pass:
  21 runs, 41 assertions.
- Full suite passes:
  221 runs, 527 assertions.
- Rage Europe with Start tapping still does not reach menu:
  `PSX_START_AT_CYCLES=250_000_000 PSX_CYCLES=2_500_000_000`
  remains black, though it keeps executing game code. Screenshots in
  `conformance-shots/rage-eu-start-skip/` are all black.

Current black-screen evidence:

- Rage initially draws/fades visible framebuffer pages (`0..319` and
  `0..239/240..479`) during the first ~100M cycles.
- Around ~150M cycles, display gets disabled and the game enters the
  intro/FMV path. Later screenshots are black even with Start taps.
- GPU command tracing shows lots of GP0/GP1 activity and loaded texture/asset
  data in VRAM, but no visible menu framebuffer.
- The next target is the MDEC/XA intro path: determine whether the game is
  waiting on MDEC output, CD-XA filtering/audio-sector handling, or a later
  DMA/GPU handoff before enabling display again.

Rage Racer Europe no longer wedges in the `0x8006B8xx` foreground CD wait.
Two CD-ROM fixes moved it past the loader:

- CD command responses are now scheduled by remaining time instead of being
  blocked behind the oldest pending response. Responses from the same command
  still preserve order, so `ReadN + Pause` continues to deliver the in-flight
  INT1 before Pause's INT3. This fixes the Rage pattern where a new INT3 ack
  was trapped behind an older delayed Pause INT2 and the game repeatedly
  reissued SetLoc/Pause until the pending queue grew without bound.
- The previous `whole_sector` `next_sector_cycles == 1` compatibility shortcut
  was removed. With the response/DMA fixes in place, that shortcut is harmful:
  Rage streams from LBA 16 to the end of data track 1 (`59542`) before its
  timer-driven loader can react, then falls into seek-error responses
  (`BAF0=06`, `BAF8=06 04`). Whole-sector reads now use the nominal 1x/2x
  cadence again.

Verification:

- `mise exec -- ruby -Ilib -Ispec spec/cdrom_spec.rb` passes:
  6 runs, 17 assertions.
- `mise exec -- rake test` passes:
  220 runs, 525 assertions.
- Rage Europe smoke:
  `PSX_DISC="$HOME/Downloads/Rage Racer (Europe)/Rage Racer (Europe)/Rage Racer (Europe).cue" PSX_CYCLES=2_000_000_000 PSX_CHUNK=250_000_000 PSX_OUT=conformance-shots/rage-eu-2b-nominal-sector mise exec -- ruby bin/_ridge-boot --fast-boot`
  leaves the old loader loop and runs through normal game addresses
  (`80039CD8`, `800337BC`, `8002D2A0`, down to `8000D914`). The framebuffer is
  still black at the 1B and 2B screenshots, so the remaining blocker has moved
  from CD loader progress to later intro/render output.

## Tree

- Branch: `main`, pushed to `khasinski/psx` (commit `ad38caa`).
- 216/216 unit tests pass.
- ps1-tests baseline: 18/21 OK (3 CDROM fails — `disc-swap`, `getloc`,
  `timing`).
- BIOS bench: ~10.7 MHz (slight drop from 11.0 MHz after the sym-mirror
  change added a mask on the hot store path).
- README updated to reflect the current feature set (MDEC, save
  states, BIOS license check fixed, current dev-tool list).
- Working tree clean except: `current_state.md` (this file).

## What landed this session

1. **Symmetric upper-RAM mirror (`ad38caa`).** Reverted the asymmetric
   "writes drop" mirror from `2991ea8` and replaced it with the real
   hardware behaviour: writes to the upper 6 MB of the RAM-decode
   region alias back to the populated 2 MB chip, same as reads. The
   asym scheme had been silently dropping Rage Racer's stack saves
   (`sw ra, 40(sp)` when `sp = 0x80200010`) and producing a misleading
   "namco splash crash" — `PC = 0x000005C4` with `A(0x40) =
   SystemErrorUnresolvedException`. Same diff in
   `Memory#write{8,16,32}` and the CPU `op_sw` inline + method paths.
   Spec test renamed to `test_upper_ram_region_mirrors_symmetrically`.

2. **README rewrite.** Section-by-section pass: dropped the obsolete
   "license check isn't bypassed" caveat (the BFRD-toggle fix in
   `cdrom.rb` resolved that), added MDEC Phase 1-3, save states,
   `ReadS` / whole_sector CD-ROM, symmetric mirror; reorganized the
   dev-tools table into runners / tracing / benchmarks; updated the
   "what doesn't" section to reflect the real remaining gaps.

## Rage Racer status

The table-population theory below was superseded by the Ruby-side trace.
The decoder tables *are* populated by the time the decoder is active:
`0x800836A8` contains `00010002` patterns and `0x800936A8` contains
non-zero Huffman/RLE entries. Around the failure, the decoder is executing
near `0x800647E0`; the live output pointer is `a1` in normal RAM
(`0x800D18E6` in the captured run), while `fp = 0x80200000` is not the
output pointer.

The actual immediate failure was an IRQ trap through an empty low-RAM
exception vector. At the decoder, `SR=40000401`, `I_MASK=0xD`; later
`I_STAT=0x5`, so an interrupt is deliverable. Since this emulator does not
model the BIOS' cache-resident low exception setup, `0x80000080` remains
zero; taking the IRQ jumps into a long NOP sled and strands the game.

Current fixes:

- `lib/psx/cpu.rb`: defer hardware IRQ delivery while `0x80000080` reads
  as zero. This avoids the immediate IRQ-to-empty-vector trap.
- `lib/psx/dma.rb`: CD-ROM DMA no longer pads past the available FIFO data
  and completes the channel early; it preserves BUSY/base/block state when
  the FIFO empties before the requested transfer completes.
- `lib/psx/cdrom.rb`: whole-sector streaming uses an accelerated sector
  cadence as a scoped compatibility guard. Without this, the game starts
  decoding from a streaming buffer before enough sectors have arrived and
  the decoder consumes zero-filled RAM.

The destructive `0x80200000` mirror write is gone through a 300M-step probe.
Rage Racer still does not reach visible game/Namco output: BIOS-shell and
fast-boot smokes now loop in the loader/wait path (`0x8006B8xx`,
`0x8006DDxx`, `0x8006E0xx`) and leave the Sony license framebuffer on screen.

Important correction from the latest pass: several earlier notes used the
wrong effective addresses for negative `lui 0x800A` offsets. For example,
`lui v1,0x800A; lw v1,-17656(v1)` is `0x8009BB08`, not `0x800ABB08`.
The interrupt/callback table is likewise at `0x80099430..0x80099460`,
and the CD/pad state area is around `0x80099300..0x80099318`.
With the corrected addresses, Rage's interrupt setup is alive:

- `0x80099430 = 00000001`
- `0x80099460 = 000D`
- callbacks include `0x8006E75C` for VBlank, `0x8006C17C` for CD-ROM,
  and `0x8006E87C` for DMA.
- `0x8009A4BC = 1F801070`, `0x8009A4C0 = 1F801074`.
- `0x8009A4EC` increments via the VBlank callback.

The current blocker is narrower than "callbacks not installed": the wait at
`0x8006B9A4` keeps seeing `0x80099318 == 0` and loops back through
`0x8006B824`. The CD callback at `0x8006C17C` does run and transiently
updates the response bytes (`0x8009BAF0`, `0x8009BAF8`, and sometimes
`0x80099318`), but the command/status byte that the foreground loop wants
does not stay in the expected state long enough for the loader to advance.

A broad "return to RA for unimplemented BIOS calls" experiment was rejected
because it breaks BIOS device setup and produces `VSync: timeout`. Treating
`B(0x17) ReturnFromException` as unconditional EPC return was also rejected:
with a live TTY handler it loops on an address-error EPC.

What we ruled out / corrected:

- Disc image is fine — extracted `SCES_006.50` directly, header magic
  `"PS-X EXE"`, text at `0x80010000..0x8009AFFF`, 571 KB.
- PS-EXE load is byte-accurate (157 mismatches out of 142336 words,
  all in legitimate runtime-data regions, not the wedge area).
- The old `bin/psx-memwatch` trace missed CPU inline load/store paths.
  It now supports `--disc`, `--fast-boot`, and logs CPU byte/half/word
  load/store opcodes as well as `Memory#write*`. It also installs hooks
  before `--fast-boot`, so startup/BSS writes are visible.
- Not an event-timing issue: `B(0x0B) TestEvent` is not called by
  the game in the 320M..355M window around the wedge.
- Duckstation lists SLUS-00403 as `NoIssues`, so a correctly
  emulated PSX does continue past this loader.

## Suggested next moves

In rough priority order:

1. **Debug the remaining loader/wait loop.** Current PCs cycle around
   `0x8006B8xx`, `0x8006DDxx`, and `0x8006E0xx` after the stream/decode
   clobber is fixed. Use the corrected addresses around `0x8006B82C`:
   `0x8009BB08`, `0x8009BB0C`, `0x8009BB10`, plus the foreground status
   byte at `0x80099318` and CD response buffers at `0x8009BAF0` and
   `0x8009BAF8`.

2. **Replace the whole-sector fast-stream guard with accurate timing.**
   The current `next_sector_cycles == 1` behavior is pragmatic and scoped,
   but not hardware-accurate. The real fix is likely better CPU/device
   pacing, interrupt callback behavior, or CD-ROM buffering.

3. **Implement a real I-cache / BIOS low-vector model.** The IRQ defer is
   still only a guard. Avoid broad BIOS-call HLE; previous broad attempts
   regressed boot.

3. **MDEC Phase 5** — CD-XA sector filtering and SPU streaming. Phase
   4 (DMA1 egress IRQ) is already wired via
   `dma.rb:set_irq_flag(MDEC_OUT)`, so Phase 5 is the only outstanding
   piece of the MDEC plan. May or may not be related to the Rage
   Racer blocker.

4. **SPU audio synthesis.** No sound currently; out of scope for the
   FMV blocker but a real gap for any retail game.

## Files of interest

- `lib/psx/memory.rb`, `lib/psx/cpu.rb` — sym-mirror change.
- `spec/memory_spec.rb` — renamed test for the mirror.
- `docs/mdec_scoping.md` — 5-phase MDEC plan (phases 1-3 + DMA1 IRQ done).
- Per-conversation memory notes under
  `~/.claude/projects/-Users-hasik-Projects-psx-ruby/memory/` (not in
  the repo). `rage_racer_upper_ram_mirror.md` has the most detailed
  trace log.
