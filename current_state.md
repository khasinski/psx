# Current state

Snapshot of where the emulator is and what we just spent time on.

The newest `Latest continuation` section is authoritative. Older historical
sections below were kept for investigation context and may describe bugs that
later entries have fixed.

## Latest continuation

2026-05-28 latest continuation:

- Added executable-level regression coverage for the MDEC frame path:
  - `spec/mdec_executable_spec.rb` now boots the ps1-tests
    `.tests/mdec/frame/frame-15bit.exe` and `frame-24bit.exe` binaries through
    the emulator, waits for their `Done` marker, and verifies that all 20
    software-read stripes were attempted/completed.
  - This locks the exact failure mode fixed by the delayed MDEC output-empty
    status bit: the 15-bit frame helper previously completed 19 stripes and
    then stalled inside the 20th `mdec_readDecoded(...)`.
  - The spec skips when the BIOS or ps1-tests frame binaries are absent.
- Verification:
  - Focused MDEC executable specs passed: `2 runs, 10 assertions, 0 failures`.
  - Full suite passed: `425 runs, 1145 assertions, 0 failures`.

- Fixed the ps1-tests MDEC frame helper hang on the final software read:
  - The actual `.tests/mdec/frame/frame-15bit.exe` executable completed 19
    stripes and then stuck inside the 20th `mdec_readDecoded(...)` call. Its
    helper polls `dataOutFifoEmpty` after every word, including the final word
    of the final stripe.
  - The Ruby MDEC model made `STAT_OUTPUT_FIFO_EMPTY` true immediately when the
    last output FIFO word was read. Hardware leaves a short status-settling
    window where an immediate post-read poll still sees the output FIFO as
    non-empty; the ps1-tests helper relies on that and exits the loop before
    the bit settles.
  - MDEC now keeps only the status empty bit delayed for a small cycle window
    after the last output word. `data_out_available?` still becomes false
    immediately, so DMA does not fabricate an extra word.
  - Added a focused MDEC regression for the delayed empty-status transition.
  - Confirmed `.tests/mdec/frame/frame-15bit.exe` now reaches `Done` after all
    20 software-read stripes. `.tests/mdec/frame/frame-24bit.exe` also reaches
    `Done`.
- Verification:
  - Focused MDEC specs passed: `15 runs, 44 assertions, 0 failures`.
  - Filtered MDEC ps1-tests baseline passed:
    `mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`;
    `TOTAL 3  OK 3  FAIL 0`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
  - Full suite passed: `423 runs, 1135 assertions, 0 failures`.

- Fixed MDEC status bits during queued decode output:
  - The ps1-tests `mdec/step-by-step-log` case exposed that after command
    input is complete but decoded output remains queued, hardware still
    reports `cmdBusy=1` while `dataInReq=0`. The Ruby model had been doing
    the inverse (`cmdBusy=0`, `dataInReq=1`) because DMA-in enable was treated
    as an unconditional request and command busy only tracked pending input.
  - MDEC status now keeps `STAT_COMMAND_BUSY` set while decoded output remains
    available, and `STAT_DATA_IN_REQ` only asserts when DMA-in is enabled and
    the active command still needs input words.
  - Added focused MDEC status regressions for the pending-input request and
    queued-output busy behavior.
- Verification:
  - Focused MDEC specs passed: `14 runs, 42 assertions, 0 failures`.
  - Filtered MDEC ps1-tests baseline passed:
    `mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`;
    `TOTAL 3  OK 3  FAIL 0`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
  - Full suite passed: `422 runs, 1133 assertions, 0 failures`.

- Follow-up audit after the Rage Grand Prix fix:
  - Re-ran the separately documented CD-ROM ps1-tests baseline with
    `PSX_TEST_DISC=tmp/ps1tests-cdrom-disc/long-mode2.cue`; it still passes
    `TOTAL 3  OK 3  FAIL 0`.
  - Checked the old `next_sector_cycles == 1` suggested move. That note is
    historical: current `next_sector_cycles` returns the normal 1x/2x sector
    cadence. The remaining `@sector_cycles = 1` path is only a retry delay
    while an already-open BFRD FIFO is partially unread, not the old whole-
    sector fast-stream cadence shortcut.
  - Fixed the stale README status line from `419/419` to `421/421` unit tests.

- Fixed the Rage Racer Grand Prix loading-screen stall after the monologue:
  - The first bad status transition was a `SeekP` (`0x16`) to LBA `59692`,
    which is track 2 audio on the Europe disc. The emulator treated all seeks
    to non-data tracks as failed data seeks, latched `SF_SEEK_ERROR`, and then
    Rage rejected every later successful `SetMode A0` ACK because the response
    status was `0x06` (`MOTOR_ON | SEEK_ERROR`).
  - Matched DuckStation's behavior for this path: physical/logical seeks to
    audio sectors complete successfully when not tied to a data read, update
    sub-Q, and clear seeking/seek-error status.
  - Streaming data reads that run into audio sectors now skip those sectors
    instead of latching seek-error; lead-out/data-end stops the stream without
    poisoning later command ACKs.
  - Added CD-ROM regressions for `SeekP` to an audio track and `ReadN`
    crossing into audio sectors without latching seek-error.
- Verification:
  - Focused CD-ROM specs passed: `61 runs, 219 assertions, 0 failures`.
  - Full suite passed: `421 runs, 1128 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
  - Rage Europe Grand Prix smoke from `tmp/rage-eu-2p4b.state` with the same
    scripted Start/Cross sequence now gets past the old `NOW LOADING` loop:
    `tmp/rage-grandprix-seek-audio/ridge-016.png` shows the car/course
    selection screen, and `tmp/rage-grandprix-seek-audio/ridge-032.png` shows
    the race-start menu. The final state has CD status `0x02` with no
    seek-error latch.

- Fixed the Rage Racer striped FMV regression from GPU DMA busy timing:
  - Bisected the visual regression with 800M-cycle Rage Europe smokes:
    `b6c22cd` and `dc0ed84` produced coherent FMV frames, while `b2b4577`
    (`Delay GPU DMA busy completion`) already showed repeated 16-pixel
    vertical striping.
  - GPU request-mode block DMA now transfers and completes immediately again;
    the synthetic busy delay remains only for manual chopping, where it was
    added for `dma/chopping`.
  - Re-arming a channel via CHCR now cancels any stale delayed completion for
    the previous transfer, so a later completion cannot clear a newly-started
    channel.
  - The installed DMA callback service now drains DMA flags raised by DMA
    callbacks in the same pass, with a hard bound, covering Rage's nested
    MDEC-out callback chain.
  - Added regressions for nested MDEC-out DMA callbacks and stale delayed GPU
    DMA completions.
- Verification:
  - Focused DMA/CPU specs passed: DMA `19 runs, 51 assertions, 0 failures`;
    CPU `30 runs, 36 assertions, 0 failures`.
  - Full suite passed: `419 runs, 1111 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
  - Rage Europe 800M-cycle smoke from a fresh fast boot produced coherent FMV
    output again; `tmp/rage-fmv-request-immediate/ridge-004.png` shows the
    red car frame without the repeated vertical striping seen in
    `tmp/rage-fmv-striped-check/ridge-004.png`.
- Previous regression, now fixed:
  - Rage Racer got stuck on the loading screen after the monologue intro when
    starting a new Grand Prix.
  - Reproduced from `tmp/rage-eu-2p4b.state` with scripted Start/Cross inputs
    through 4.0B absolute cycles. The run reaches the monologue/title flow
    around 3.0B, switches to a 320x480 `NOW LOADING` screen by
    `tmp/rage-grandprix-repro/ridge-016.png`, and is still on the same loading
    screen at `tmp/rage-grandprix-repro/ridge-032.png`.
  - The stuck PC samples cluster around Rage stream/loading code:
    `0x8006DD3C`, `0x8006DD54`, `0x8006DD80`, `0x8006B848`,
    `0x8006DEA0`, `0x8006DEB0`, `0x8006DEBC`, and `0x8006DEF0`.

- Matched DuckStation's GPU save-state GPUREAD latch behavior:
  - GPU save states now preserve `@gpu_info_latch`, matching DuckStation's
    serialized `GPUREAD_latch`.
  - Added a regression that restores a GPU after a GP1 info read and verifies
    `read_data` still returns the latched value.
- Verification:
  - Focused GPU regression spec passed: `28 runs, 72 assertions, 0 failures`.
  - Full suite passed: `417 runs, 1109 assertions, 0 failures`.
- Matched DuckStation's odd-width VRAM-to-CPU readback packing:
  - GP0 C0 readbacks now stream pixels across row boundaries before packing
    two 16-bit pixels into each GPUREAD word, instead of rounding each row up
    independently.
  - Odd total pixel counts now zero-fill the final high halfword, and the
    final GPUREAD word remains latched after the transfer returns to idle.
  - Added a regression covering a 3x3 readback where row-boundary packing and
    final zero-fill are both observable.
- Verification:
  - Focused GPU regression spec passed: `27 runs, 70 assertions, 0 failures`.
  - Full suite passed: `416 runs, 1107 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
  - Rage Europe title-state smoke from `tmp/rage-eu-2p4b.state` completed to
    3.0B absolute cycles with Start scripted from 2.45B to 2.5B; screenshot
    `tmp/rage-current-gameplay-check/ridge-012.png` shows the in-engine tunnel
    scene with coherent wall/road textures.

- Matched DuckStation's odd-sized CPU-to-VRAM upload bounds:
  - GP0 A0 transfers now track remaining pixels separately from remaining
    command data words, so the padded halfword for odd `width * height`
    uploads is consumed but not written into VRAM.
  - Save states now preserve the in-flight CPU-to-VRAM pixel counter.
  - Added a regression for a 1x1 upload whose second halfword must not
    overwrite the adjacent VRAM pixel.
- Verification:
  - Focused GPU regression spec passed: `26 runs, 63 assertions, 0 failures`.
  - Full suite passed: `415 runs, 1100 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's per-primitive CLUT snapshot behavior:
  - Textured 4-bit/8-bit rectangles and triangles now cache the active CLUT
    before rasterization instead of rereading palette entries from live VRAM
    for every pixel.
  - This prevents a primitive that draws over its own palette row from
    changing the colours of later pixels in the same draw.
  - Added a regression where a textured rectangle overwrites a CLUT entry
    before a later texel indexes that same entry.
- Verification:
  - Focused GPU regression spec passed: `25 runs, 61 assertions, 0 failures`.
  - Full suite passed: `414 runs, 1098 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
  - Rage Europe title-state smoke from `tmp/rage-eu-2p4b.state` completed to
    2.7B absolute cycles and still reached the selectable menu; screenshot
    `tmp/rage-title-clut-snapshot/ridge-006.png` shows the title/menu logo.

- Fixed Rage Racer's direct-pad Start bit for intro/title input:
  - The BIOS direct pad buffer now keeps the controller's serial low/high
    button byte order (`00 41 F7 FF` for Start) instead of normalizing it to
    high/low order.
  - Rage's pad updater decodes direct bytes as `~(byte2 << 8 | byte3)`, and
    its intro skip path checks the Start edge at bit `0x0800`; the old
    high/low shim decoded Start as `0x0008`.
  - A title-state smoke from `tmp/rage-eu-2p4b.state` still reaches the Rage
    selectable menu with the serial-order buffer, and an intro probe hit the
    skip branch at `0x8001EA08`/`0x80042CCC` after a released-to-pressed
    Start transition.
- Verification:
  - Focused emulator spec passed: `5 runs, 7 assertions, 0 failures`.
  - Focused SIO0 spec passed: `21 runs, 55 assertions, 0 failures`.
  - Full suite passed: `413 runs, 1096 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's semi-transparent line blending:
  - GP0 line and polyline commands now honor the semi-transparency opcode bit
    and blend non-textured line pixels through the active E1 blend mode.
  - Added a regression for the default half-add blend over an existing VRAM
    background pixel.
- Verification:
  - Focused GPU regression spec passed: `24 runs, 59 assertions, 0 failures`.
  - Full suite passed: `412 runs, 1094 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's modulated textured triangle dither:
  - Textured polygons with modulation now apply the draw-mode dither matrix
    after texture/color multiplication and before the final 5-bit channel
    reduction when E1 bit 9 is enabled.
  - Added a regression that distinguishes the positive and negative dither
    entries on a low-intensity modulated texel.
- Verification:
  - Focused GPU regression spec passed: `23 runs, 58 assertions, 0 failures`.
  - Full suite passed: `411 runs, 1093 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's line color stepping/dither behavior:
  - Gouraud lines now advance their color interpolation across plotted pixels
    instead of reusing the first vertex color for every pixel.
  - Line primitives now apply the draw-mode dither matrix when E1 bit 9 is
    enabled, matching DuckStation's `IsDitheringEnabled` rule for lines.
- Verification:
  - Focused GPU regression spec passed: `22 runs, 56 assertions, 0 failures`.
  - Full suite passed: `410 runs, 1091 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation's GPU dither matrix for Gouraud triangles:
  - Non-textured shaded triangles now apply the 4x4 draw-mode dither matrix
    before reducing 8-bit RGB channels to 5-bit VRAM values when E1 bit 9 is
    enabled.
  - Added a regression that checks both a positive and negative matrix entry.
- Verification:
  - Focused GPU regression spec passed: `20 runs, 51 assertions, 0 failures`.
  - Full suite passed: `408 runs, 1086 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's VRAM-to-VRAM copy edge behavior:
  - VRAM copies now skip true no-op self-copies unless the draw mask bit must
    be set, matching DuckStation's copy command guard.
  - Same-row overlapping copies now copy right-to-left when the destination is
    after the source, so the original source pixels are preserved.
  - VRAM copies now honor draw mask set/check bits, preserving masked
    destination pixels and setting bit 15 on copied pixels when requested.
- Verification:
  - Focused GPU regression spec passed: `19 runs, 49 assertions, 0 failures`.
  - Focused ps1-tests `gpu/bandwidth` passed: `TOTAL 1  OK 1  FAIL 0`.
  - Full suite passed: `407 runs, 1084 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's reserved direct texture mode:
  - GPU texture mode `3` now aliases direct 15/16-bit texture sampling instead
    of returning transparent texels, matching DuckStation's
    `Reserved_Direct16Bit` handling.
  - Added a raw textured rectangle regression for the reserved mode.
- Verification:
  - Focused GPU regression spec passed: `17 runs, 44 assertions, 0 failures`.
  - Full suite passed: `405 runs, 1079 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's pending-key repeat-address write behavior:
  - A voice repeat-address write between KEY_ON and the next SPU sample now
    keeps the voice in its first-block loop-start window, instead of treating
    the deferred voice as fully off and suppressing the first loop-start flag.
  - Added a regression for the pending KON repeat-write path.
- Verification:
  - Focused SPU spec passed: `69 runs, 187 assertions, 0 failures`.
  - Full suite passed: `404 runs, 1078 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's pending SPU KON/KOFF application timing:
  - KEY_ON/KEY_OFF writes now update the readable latches first and apply
    voice start/release after the next generated SPU sample, matching
    DuckStation's pending-register lifecycle.
  - The first generated sample after KON still reflects the pre-key state;
    the voice starts on the following sample. Specs now make that frame
    boundary explicit.
- Verification:
  - Focused SPU spec passed: `68 runs, 185 assertions, 0 failures`.
  - Full suite passed: `403 runs, 1076 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Extended SPU transfer IRQ coverage to DMA reads:
  - Added the read-side companion regression for DuckStation's after-halfword
    RAM IRQ check when DMA reads advance the SPU transfer pointer onto the
    next 8-byte IRQ-address boundary.
- Verification:
  - Focused SPU spec passed: `68 runs, 177 assertions, 0 failures`.
  - Full suite passed: `403 runs, 1068 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's SPU transfer RAM IRQ timing:
  - Manual and DMA SPU RAM transfers now check the RAM IRQ address after each
    halfword advances the transfer pointer, instead of before individual byte
    accesses.
  - Added regressions for IRQs firing exactly when a manual/DMA transfer lands
    on the next 8-byte IRQ-address boundary.
- Verification:
  - Focused SPU spec passed: `67 runs, 173 assertions, 0 failures`.
  - Full suite passed: `402 runs, 1064 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's deferred SPU next-block decode timing:
  - Advancing past the end of an ADPCM block now clears the current decoded
    block and leaves the next block to be decoded on the next SPU sample,
    matching DuckStation's `has_samples = false` transition.
  - Gaussian interpolation history still keeps the previous block tail for the
    next decode.
  - Late RAM IRQ checks now skip a just-advanced voice until that next block
    has actually been sampled.
- Verification:
  - Focused SPU spec passed: `65 runs, 165 assertions, 0 failures`.
  - Full suite passed: `400 runs, 1056 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's deferred SPU key-on ADPCM decode timing:
  - Key-on now resets voice sample state and marks the voice ready to start,
    but the first ADPCM block is decoded on the next SPU sample rather than
    during the key-on register write.
  - Late RAM IRQ checks now naturally skip a just-keyed voice until its first
    block has actually been sampled, matching DuckStation's `has_samples`
    guard in `CheckForLateRAMIRQs`.
- Verification:
  - Focused SPU spec passed: `64 runs, 159 assertions, 0 failures`.
  - Full suite passed: `399 runs, 1050 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU Gaussian voice interpolation:
  - Voices now keep the previous three decoded samples as interpolation
    history.
  - Sample output now uses DuckStation's 512-entry Gaussian table and
    `sample_counter` interpolation index instead of reading the raw decoded
    sample.
  - Save states preserve interpolation history for each voice, with
    backward-compatible restore from decoded samples.
- Verification:
  - Focused SPU spec passed: `63 runs, 155 assertions, 0 failures`.
  - Full suite passed: `398 runs, 1046 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's SPU key-off and loop-end force-off state:
  - Key-off now ignores voices that are already off or already in release,
    matching DuckStation's `Voice::KeyOff`.
  - Loop-end without repeat now fully forces the voice off when noise is not
    enabled, clearing ADSR phase and current ADSR volume instead of only
    clearing Ruby's active-mask bit.
- Verification:
  - Focused SPU spec passed: `61 runs, 156 assertions, 0 failures`.
  - Full suite passed: `396 runs, 1047 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's zero-pitch SPU voice sampling order:
  - Voices now compute `last_volume` and tick ADSR before applying the pitch
    step, so pitch `0` does not leave stale voice volume behind.
  - Sample position still does not advance when pitch is zero.
- Verification:
  - Focused SPU spec passed: `60 runs, 152 assertions, 0 failures`.
  - Full suite passed: `395 runs, 1043 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched DuckStation's IRQ9-driven sampling for inactive SPU voices:
  - Inactive voices now clear stale `last_volume` during normal samples, so
    capture buffers no longer preserve old voice 1/3 levels after a voice is
    off.
  - When SPUCNT IRQ9 is enabled, inactive voices still decode/advance ADPCM
    blocks so RAM IRQs can fire from their current sample addresses, matching
    DuckStation's `SampleVoice` path.
  - Pitch-modulation coverage now uses an active previous voice, matching the
    fact that inactive previous voices clear `last_volume` before later voices
    are sampled.
- Verification:
  - Focused SPU spec passed: `59 runs, 149 assertions, 0 failures`.
  - Full suite passed: `394 runs, 1040 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Extended scalar SPU reverb work-buffer coverage:
  - Added focused regressions proving SPUCNT reverb master enable controls
    whether the reverb comb/all-pass stage writes mix destinations back into
    SPU RAM.
  - The disabled case still computes upsample output but leaves work RAM
    unchanged, matching DuckStation's `reverb_master_enable` write gates.
- Verification:
  - Focused SPU spec passed: `57 runs, 145 assertions, 0 failures`.
  - Full suite passed: `392 runs, 1036 assertions, 0 failures`.

- Replaced the simple SPU reverb delay tap with a scalar DuckStation-backed
  work-buffer path:
  - Reverb input is now written through the 64-step downsample history buffer
    and processed on odd resample phases.
  - The reverb parameter block now drives IIR, comb, all-pass, mix-destination,
    and upsample-buffer stages instead of reading only the current work-area
    address as a delay line.
  - Save states preserve the downsample and upsample history buffers.
  - This is a major step toward DuckStation/Mednafen reverb behavior, but the
    SPU audio path still needs broader conformance testing before calling it
    hardware-complete.
- Verification:
  - Focused SPU spec passed: `55 runs, 143 assertions, 0 failures`.
  - Full suite passed: `390 runs, 1034 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Extended SPU late RAM IRQ coverage:
  - Added the companion regression for writing `SPU_IRQ_ADDR` while IRQ9 is
    already enabled and an active decoded voice overlaps the requested IRQ
    address.
- Verification:
  - Focused SPU spec passed: `54 runs, 136 assertions, 0 failures`.
  - Full suite passed: `389 runs, 1027 assertions, 0 failures`.

- Matched DuckStation's late SPU RAM IRQ checks for decoded voices:
  - Enabling IRQ9 or writing the IRQ address now scans the current transfer
    pointer plus active voices with decoded ADPCM samples.
  - Active voice checks compare both the current ADPCM block byte address and
    the next block address, matching DuckStation's `CheckForLateRAMIRQs`.
- Verification:
  - Focused SPU spec passed: `53 runs, 134 assertions, 0 failures`.
  - Full suite passed: `388 runs, 1025 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed coverage for SPU capture-buffer RAM IRQs:
  - Capture-buffer writes now have an explicit regression proving they trigger
    SPU IRQ9 when `irq_address * 8` matches the capture buffer write address,
    matching DuckStation's `WriteToCaptureBuffer` path.
- Verification:
  - Focused SPU spec passed: `52 runs, 132 assertions, 0 failures`.
  - Full suite passed: `387 runs, 1023 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched SPUCNT mute behavior against DuckStation:
  - When SPUCNT bit 14 (`mute_n`) is clear, voice mix and voice reverb input
    are muted before CD audio is mixed.
  - CD audio still follows its own enable/reverb bits after the mute gate,
    matching DuckStation's mixer ordering.
- Verification:
  - Focused SPU spec passed: `51 runs, 130 assertions, 0 failures`.
  - Full suite passed: `386 runs, 1021 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Matched SPU reverb work-area addressing against DuckStation:
  - Reverb current/base addresses are now treated as halfword-address units,
    with byte conversion at RAM access time.
  - Reverb RAM access now wraps inside the configured work area using
    DuckStation's base-add-on-overflow rule.
- Verification:
  - Focused SPU spec passed: `49 runs, 125 assertions, 0 failures`.
  - Full suite passed: `384 runs, 1016 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU capture-buffer writes:
  - Each generated SPU sample now writes raw CD left/right samples and voice
    1/3 last-volume levels to the four 0x400-byte capture buffers in SPU RAM.
  - Capture position advances by one halfword per sample and updates SPUSTAT
    bit 11 when it enters the second half of the buffer.
  - Capture position is preserved in save states.
- Verification:
  - Focused SPU spec passed: `48 runs, 124 assertions, 0 failures`.
  - Full suite passed: `383 runs, 1015 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Tightened the SPU reverb work-address cadence against DuckStation:
  - The simple reverb delay-line return now tracks a 64-step resample phase.
  - The reverb current address advances only on odd resample phases, matching
    DuckStation's 44.1 kHz input / 22.05 kHz work-buffer cadence.
  - Save states preserve the reverb resample phase.
- Verification:
  - Focused SPU spec passed: `46 runs, 116 assertions, 0 failures`.
  - Full suite passed: `381 runs, 1007 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added a bounded DuckStation-backed SPU reverb mixer hook:
  - The SPU mixer now accumulates reverb sends from voices whose
    `REVERB_ON` bit is set and from CD audio when SPUCNT bit 2 is set.
  - A simple SPU-RAM delay-line return is mixed before main volume. It uses
    the configured reverb base/current address and raw signed reverb output
    volumes (`0xD84/0xD86`).
  - SPUCNT bit 7 controls whether new send samples are written into the
    delay line. The full DuckStation/Mednafen reverb algorithm is still a
    remaining gap; this commit adds the send/return wiring and persistent
    state needed to replace the simple internals later.
  - Save states now preserve reverb current address plus last input/output
    levels.
- Verification:
  - Focused SPU spec passed: `45 runs, 112 assertions, 0 failures`.
  - Full suite passed: `380 runs, 1003 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU key latch clearing:
  - KON/KOFF registers still start/release voices immediately in Ruby, but
    their readable latch values now clear on the next generated SPU sample,
    matching DuckStation's pending-register lifecycle more closely.
- Verification:
  - Focused SPU spec passed: `43 runs, 101 assertions, 0 failures`.
  - Full suite passed: `378 runs, 992 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU external volume registers:
  - External input volumes (`0xDB4/0xDB6`) are now explicit stateful
    read/write registers and are preserved by save states.
- Verification:
  - Focused SPU spec passed: `42 runs, 97 assertions, 0 failures`.
  - Full suite passed: `377 runs, 988 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU current main-volume writes:
  - Writes to current main-volume registers (`0xDB8/0xDBA`) now update the
    live main output levels used by the mixer.
- Verification:
  - Focused SPU spec passed: `41 runs, 93 assertions, 0 failures`.
  - Full suite passed: `376 runs, 984 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU reverb register surface:
  - Reverb output volumes (`0xD84/0xD86`), reverb base (`0xDA2`), and the
    32-word reverb parameter block (`0xDC0..0xDFE`) are now stateful and
    readable.
  - Save states preserve those reverb registers in addition to the existing
    reverb voice mask. This is still register coverage, not reverb mixing.
- Verification:
  - Focused SPU spec passed: `40 runs, 89 assertions, 0 failures`.
  - Full suite passed: `375 runs, 980 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU volume-sweep ticking:
  - Main and per-voice volume registers in sweep mode now keep an envelope
    and advance their current-volume levels once per produced SPU sample.
  - Sweep state is included in save states.
- Verification:
  - Focused SPU spec passed: `39 runs, 80 assertions, 0 failures`.
  - Full suite passed: `374 runs, 971 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU fixed-volume/current-volume behavior:
  - Main and per-voice volume writes now reset a separate current-volume
    level instead of using the raw register bits directly during mixing.
  - Fixed-volume registers now use DuckStation's signed 15-bit, shifted-left
    interpretation; for example `0x3FFF` becomes `0x7FFE`, `0x4000` becomes
    `0x8000`, and `0x7FFF` becomes `0xFFFE`.
  - Current main-volume reads (`0xDB8/0xDBA`) and current per-voice volume
    reads (`0xE00..0xE5E`) now expose those live levels.
- Verification:
  - Focused SPU spec passed: `37 runs, 78 assertions, 0 failures`.
  - Full suite passed: `372 runs, 969 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU repeat-address side effects:
  - Writing a voice ADPCM repeat address (`VxADSR repeat`, offset `0x0E`)
    now updates the live voice state, not just the register shadow.
  - Voices now track first-block state and the explicit-repeat-address
    `ignore_loop_address` latch. A loop-start ADPCM block still sets the
    repeat address during the key-on first-block window, but later explicit
    repeat writes are preserved instead of being overwritten by subsequent
    loop-start flags.
- Verification:
  - Focused SPU spec passed: `36 runs, 74 assertions, 0 failures`.
  - Full suite passed: `371 runs, 965 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU ADSR register side effects:
  - Writing ADSR low/high (`VxADSR1/2`) while a voice is active now rebuilds
    the live ADSR envelope instead of only updating the register shadow.
  - Writing the ADSR current-volume register now updates the live voice
    volume used by subsequent samples.
- Verification:
  - Focused SPU spec passed: `34 runs, 72 assertions, 0 failures`.
  - Full suite passed: `369 runs, 963 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-style GPU block DMA completion timing:
  - GPU block DMA now transfers data immediately but keeps CHCR busy until a
    RAM access delay of `words + ceil(words / 16)` cycles elapses, matching
    DuckStation's `Bus::GetDMARAMTickCount` shape.
  - Manual sync-mode 0 chopping adds DuckStation's capped CPU-window delay
    (`min(cpu_window * blocks, 500)`) before CHCR busy clears.
  - Pending DMA completions suppress channel re-entry while the busy bit is
    waiting to clear.
  - Raw `dma/chopping` output now reports around `2176` CPU cycles for the
    8192-byte GPU block DMA instead of the old immediate `29`-cycle class;
    this is closer but still not hardware bit-perfect.
- Verification:
  - Focused DMA spec passed: `18 runs, 51 assertions, 0 failures`.
  - Focused ps1-tests `dma/chopping` passed: `TOTAL 1  OK 1  FAIL 0`.
  - Full suite passed: `367 runs, 961 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added DuckStation-backed SPU register coverage for the per-voice noise and
  reverb masks:
  - Ruby now exposes `NOISE_MODE_LOW/HIGH` (`0x1F801D94/96`) and
    `REVERB_ON_LOW/HIGH` (`0x1F801D98/9A`) as stateful readable registers,
    matching DuckStation's `noise_mode_register` and `reverb_on_register`
    paths.
  - Save states preserve both masks so quicksave/quickload does not lose
    these SPU control bits.
- Verification:
  - Focused SPU spec passed: `30 runs, 64 assertions, 0 failures`.
  - Full suite passed: `363 runs, 948 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.
- Added a minimal DuckStation/PCSX-R-backed SPU noise path:
  - Ruby now advances the SPU noise generator from SPUCNT noise-clock bits,
    substitutes the generated noise level for ADPCM samples when a voice's
    noise mask bit is enabled, and preserves `@noise_count` / `@noise_level`
    in save states.
  - Loop-end mute is ignored for noise-enabled voices, matching DuckStation's
    voice block handling.
  - README SPU status now distinguishes basic noise/pitch support from the
    remaining reverb/full-ADSR gaps.
- Verification:
  - Focused SPU spec passed: `32 runs, 70 assertions, 0 failures`.
  - Full suite passed: `365 runs, 954 assertions, 0 failures`.
  - Default ps1-tests baseline passed: `TOTAL 18  OK 18  FAIL 0`.

- Added runnable regression coverage for the latest Rage title/input and GPU
  texture investigations:
  - `spec/emulator_spec.rb` now proves the normal `run(steps:)` fast path
    refreshes the BIOS direct pad buffer in the high/low byte order that Rage
    reads for Start.
  - `spec/gpu_regression_spec.rb` now locks DuckStation's texture-window
    ordering for textured rectangles: the window remaps U before 8-bit byte
    or 4-bit nibble texture lookup.
- Verification:
  - Focused emulator spec passed: `4 runs, 5 assertions, 0 failures`.
  - Focused GPU regression spec passed: `16 runs, 43 assertions, 0 failures`.
  - Full suite passed: `360 runs, 940 assertions, 0 failures`.
- Re-ran the Rage Europe title-state resume smoke after that spec commit:
  - Command:
    `PSX_LOAD_STATE=tmp/rage-eu-2p4b.state PSX_BASE_CYCLES=2400000000 PSX_CYCLES=300000000 PSX_CHUNK=25000000 PSX_SCREENSHOT_EVERY_CHUNKS=1 PSX_INPUT_SCRIPT=start:2450000000:2500000000 PSX_OUT=conformance-shots/rage-eu-title-resume-latest ... bin/_ridge-boot`
  - Completed to 2.7B absolute cycles without CPU errors.
  - `ridge-004.png` shows the title Start transition to `BRISE GP` /
    `"OVER PASS CITY"`.
  - `ridge-008.png` and `ridge-012.png` show the in-engine attract/race
    scene.

- Fixed CD-ROM SeekL completion for data tracks. DuckStation completes a
  logical seek by processing the target sector header, which makes GetlocL
  valid after SeekL even before streaming reads begin. Ruby now reads the
  target data sector during successful SeekL completion, updates the cached
  header/subheader/SubQ state, clears stale seek errors, and returns an INT5
  seek error for targets outside a data track instead of reporting a false
  completion. Failed seeks also invalidate the cached GetlocL/GetlocP state,
  matching ps1-tests' expectation that location queries fail after a seek
  error.
- Added CD-ROM regression specs for GetlocL immediately after SeekL and for
  out-of-range SeekL failure, including the follow-up GetlocL/GetlocP errors.
- Verification:
  - Focused CD-ROM spec passed: `52 runs, 170 assertions, 0 failures`.
  - Full suite passed: `350 runs, 900 assertions, 0 failures`.
  - ps1-tests `cdrom/getloc` with a synthetic disc now gets past the
    data-track SeekL/GetlocL mismatch. It exposed a separate pregap edge:
    `SetLoc 00:00:30` maps to negative LBA `-120`, and real hardware accepts
    it.
- Added minimal implicit track-one pregap handling. A seek to logical LBAs in
  `-150...0` now succeeds against data track 1 and fabricates a mode-2
  header/subheader for GetlocL; this covers the ps1-tests `SetLoc 00:00:30`
  case, which reports header `[00:00:29]`.
- Verification for pregap seek:
  - Focused CD-ROM spec passed: `53 runs, 176 assertions, 0 failures`.
  - Focused disc spec passed: `8 runs, 128 assertions, 0 failures`.
  - Full suite passed: `351 runs, 906 assertions, 0 failures`.
  - A live `cdrom/getloc` probe with the synthetic disc timed out before
    emitting comparable test output, so this path is covered by regression
    specs but not yet by a full ps1-tests pass.
- Fixed `bin/_ps1tests-baseline` so it no longer hardcodes system
  `bundle exec`. It now defaults to `mise exec -- ruby` when mise is
  available, supports `PSX_TEST_RUNNER`, `PSX_MAX_CYCLES`,
  `PSX_WALL_TIMEOUT`, `PSX_TEST_FILTER`, and `PSX_TEST_DISC`, and can attach
  a disc image for `cdrom/*` tests.
- Verification for the runner fix:
  - `bash -n bin/_ps1tests-baseline` passed.
  - `PSX_TEST_FILTER=cpu/cop PSX_MAX_CYCLES=100000000 bin/_ps1tests-baseline`
    passed: `TOTAL 1  OK 1  FAIL 0`.
- Fixed the remaining `cdrom/getloc` execution blockers against ps1-tests:
  - `bin/psx-test` now stops and normalizes on `Test passed` / `Test failed`
    markers, which these ps1-tests use instead of `Done.`.
  - `CdlInit` preserves the last valid GetlocL/GetlocP cache instead of
    treating it like first power-on.
  - Far `SetLoc` + `ReadN` keeps the drive status at `SEEKING|MOTOR_ON`
    until the first sector arrives, including the psn00bsdk pattern that
    issues `Pause` before that first sector is ready.
- Verification for `cdrom/getloc`:
  - Focused CD-ROM spec passed: `56 runs, 193 assertions, 0 failures`.
  - `PSX_TEST_FILTER=cdrom/getloc PSX_TEST_DISC=tmp/ps1tests-cdrom-disc/long-mode2.cue PSX_MAX_CYCLES=250000000 PSX_WALL_TIMEOUT=45 bin/_ps1tests-baseline`
    passed: `TOTAL 1  OK 1  FAIL 0`.
  - Full suite passed: `354 runs, 923 assertions, 0 failures`.
- Added an explicit CD-ROM eject/insert path and used it in `bin/psx-test`
  to automate ps1-tests' interactive `cdrom/disc-swap` prompts. Eject now
  raises an INT5 shell-open error, insert reports the observed `0x12`,
  `0x10`, `0x00` GetStat sequence, and psx-test stops after the disc is
  detected.
- Verification for `cdrom/disc-swap`:
  - Focused CD-ROM and savestate specs passed:
    `58 runs, 203 assertions, 0 failures`.
  - `PSX_TEST_FILTER=cdrom/disc-swap PSX_TEST_DISC=tmp/ps1tests-cdrom-disc/long-mode2.cue PSX_MAX_CYCLES=120000000 PSX_WALL_TIMEOUT=45 bin/_ps1tests-baseline`
    passed: `TOTAL 1  OK 1  FAIL 0`.
  - Full suite passed: `356 runs, 933 assertions, 0 failures`.
- Fixed the `cdrom/timing` stall. The timing test waits for sector IRQs but
  never opens BFRD or drains the data FIFO; Ruby was blocking the stream on an
  unread normal-mode data buffer anyway. Streaming now only blocks on unread
  sector data after BFRD has been opened, so IRQ-only timing loops keep
  receiving sector interrupts.
- Added a CD-ROM regression spec for closed-BFRD unread FIFO behavior.
- `bin/psx-test` now stops `cdrom/timing` after the fifth double-speed timing
  line, since the test has no explicit terminal marker and then loops.
- Verification for `cdrom/timing`:
  - Focused CD-ROM spec passed: `59 runs, 207 assertions, 0 failures`.
  - `PSX_TEST_FILTER=cdrom/timing PSX_TEST_DISC=tmp/ps1tests-cdrom-disc/long-mode2.cue PSX_MAX_CYCLES=500000000 PSX_WALL_TIMEOUT=180 bin/_ps1tests-baseline`
    passed: `TOTAL 1  OK 1  FAIL 0`.
  - Full CD-ROM baseline with the synthetic disc passed:
    `TOTAL 3  OK 3  FAIL 0`.
  - Full suite passed: `357 runs, 937 assertions, 0 failures`.
- Adjusted `bin/_ps1tests-baseline` so default runs skip `cdrom/*` when
  `PSX_TEST_DISC` is not set. Those tests require a mounted disc image, and
  treating no-media runs as emulator failures made the broad baseline noisy.
- Verification:
  - `bash -n bin/_ps1tests-baseline` passed.
  - `PSX_TEST_FILTER=cdrom PSX_MAX_CYCLES=1000000 PSX_WALL_TIMEOUT=5 bin/_ps1tests-baseline`
    reports all three CD-ROM tests as skipped and `TOTAL 0  OK 0  FAIL 0`.
- Added a generic early-stop path to `bin/psx-test` for reference logs with
  no PASS/FAIL/Done markers. Once the captured output contains every expected
  reference line, with numeric fields treated fuzzily, the runner stops
  instead of burning the full cycle quota. This makes structural-output tests
  like `dma/chain-looping` complete promptly.
- Verification:
  - `mise exec -- ruby -c bin/psx-test` passed.
  - `PSX_TEST_FILTER=dma/chain-looping PSX_MAX_CYCLES=120000000 PSX_WALL_TIMEOUT=45 bin/_ps1tests-baseline`
    passed: `TOTAL 1  OK 1  FAIL 0`.
- Remaining default-baseline notes:
  - Rechecked the slow default-baseline cases sequentially rather than in
    parallel. `mdec/4bit`, `mdec/8bit`, `mdec/step-by-step-log`, and
    `gpu/bandwidth` all pass with a 90s wall cap.
  - Default ps1-tests baseline with CD-ROM tests skipped unless
    `PSX_TEST_DISC` is set now passes: `TOTAL 18  OK 18  FAIL 0`.
  - Full CD-ROM baseline with the synthetic disc remains separately covered:
    `TOTAL 3  OK 3  FAIL 0`.
- Current Rage Europe smoke on the latest tree:
  - Command:
    `PSX_DISC="$HOME/Downloads/Rage Racer (Europe)/Rage Racer (Europe)/Rage Racer (Europe).cue" PSX_CYCLES=2800000000 PSX_CHUNK=200000000 PSX_START_AT_CYCLES=1000000000 PSX_OUT=conformance-shots/rage-eu-current-baseline mise exec -- ruby --yjit bin/_ridge-boot --fast-boot`
  - Completed to 2.8B cycles without CPU errors.
  - `conformance-shots/rage-eu-current-baseline/ridge-012.png` shows the full
    Rage Racer title logo and `PRESS START`.
  - `conformance-shots/rage-eu-current-baseline/ridge-014.png` reaches the
    in-engine attract scene.
- Added `bin/_ridge-boot` resume/probe support for tighter Rage input
  experiments:
  - `PSX_LOAD_STATE` restores an emulator state instead of booting from
    scratch.
  - `PSX_BASE_CYCLES` keeps input-script timestamps absolute after resume.
  - `PSX_SCREENSHOT_EVERY_CHUNKS` controls screenshot cadence.
- Current title-state probe:
  - Saved `tmp/rage-eu-2p4b.state` from a 2.4B-cycle Rage Europe run; the
    paired screenshot shows the title screen.
  - Resuming from that state with Start taps at `2.45B..2.50B`,
    `2.60B..2.65B`, and `2.75B..2.80B` updates the direct pad buffer to
    `00 41 FF F7` during the tap windows, confirming Start reaches Rage's
    pad buffer in the current tree.
  - Visual captures under `conformance-shots/rage-eu-title-resume-taps/`
    still show the flow entering attract/race scenes rather than a captured
    menu transition, so the exact title Start/menu behavior remains a
    follow-up target.
- Follow-up resume probe with dense captures:
  - Command:
    `PSX_LOAD_STATE=tmp/rage-eu-2p4b.state PSX_BASE_CYCLES=2400000000 PSX_CYCLES=300000000 PSX_CHUNK=25000000 PSX_SCREENSHOT_EVERY_CHUNKS=1 PSX_INPUT_SCRIPT=start:2450000000:2500000000 ... bin/_ridge-boot`
  - `conformance-shots/rage-eu-title-resume-edge/ridge-001.png` starts on the
    title screen.
  - `ridge-004.png` shows the Start transition to `BRISE GP` /
    `"OVER PASS CITY"`.
  - `ridge-006.png` overlays that event text on the in-engine tunnel scene,
    and `ridge-008.png` continues into the attract/race scene.
  - This proves the current tree accepts a title-screen Start edge in Rage
    Europe; the earlier full-run hold window missed the edge and only proved
    eventual attract mode.

- Removed the earlier rectangle texture-flip behavior. That code was based on
  a Rage-title hypothesis; DuckStation's current software and hardware
  rectangle paths do not consume draw-mode bits 12/13 when stepping sprite
  U/V coordinates, and instead sample rectangles forward from the command
  texcoord. Ruby now matches that behavior.
- Reworked the GPU regression specs for E1 bits 12/13 to assert
  DuckStation-backed forward rectangle sampling rather than mirrored sampling.
- Verification for the rectangle sampling change:
  - Focused GPU regression spec passed: `14 runs, 41 assertions, 0 failures`.
  - Focused GPU spec passed: `15 runs, 37 assertions, 0 failures`.
  - Full suite passed: `348 runs, 883 assertions, 0 failures`.
  - Rage Europe smoke to 2.8B cycles with Start held from 1.0B reached the
    title and attract path. `conformance-shots/rage-eu-rect-no-flip-title/ridge-012.png`
    shows the full Rage Racer title logo and `PRESS START`; `ridge-014.png`
    shows the in-engine attract scene.

- Fixed 24-bit GPU display scanout byte order. DuckStation's software and
  hardware scanout paths read 24-bit VRAM bytes as R/G/B; Ruby's framebuffer
  extractor was interpreting the same bytes as B/G/R. This left the now-RGB
  MDEC output visibly blue-swapped in screenshots and display output.
- Updated the GPU framebuffer spec to assert RGB byte order for consecutive
  24-bit display pixels.
- Verification for the 24-bit scanout fix:
  - Focused GPU spec passed: `15 runs, 37 assertions, 0 failures`.
  - Focused GPU regression spec passed: `14 runs, 41 assertions, 0 failures`.
  - Full suite passed: `348 runs, 883 assertions, 0 failures`.
  - Rage Europe smoke to 1.6B cycles with Start held from 1.0B stayed stable
    in the 24-bit intro path. Fresh screenshots under
    `conformance-shots/rage-eu-24bit-scanout-rgb/` show the car and clock FMV
    with the intended red palette at `ridge-004.png` and `ridge-008.png`.

- Fixed the MDEC IDCT/dequant precision path against DuckStation's current
  decoder. The Ruby decoder was dequantising into an 11-bit coefficient range
  before IDCT and using a simpler pass formula; full-frame output was
  recognizable but had a strong 8x8 block lattice. The decoder now keeps
  DuckStation's four fractional coefficient bits, uses the row-major zigzag
  layout, applies the same coefficient sign correction, and runs the two-pass
  integer IDCT with `+0x20000 >> 18` rounding and final 9-bit sign extension.
- Added an MDEC regression spec that decodes ps1-tests'
  `.tests/mdec/frame/sunset.mdec`, applies the same 15-bit block swizzle used
  by the ps1-tests helper, and samples the resulting VRAM image against the
  `vram-15bit.png` reference.
- Verification:
  - Focused MDEC spec passed: `13 runs, 37 assertions, 0 failures`.
  - ps1-tests `mdec/4bit`, `mdec/8bit`, and `mdec/step-by-step-log` all still
    match their marker expectations.
  - Full suite passed: `348 runs, 883 assertions, 0 failures`.
  - Direct ps1-tests frame check improved from a visibly gridded sunset frame
    to a coherent image; the sampled reference spec now covers this path.
  - Rage Europe smoke to 1.6B cycles with Start held from 1.0B stayed stable
    in the 24-bit intro path. Screenshots under
    `conformance-shots/rage-eu-mdec-idct/` show coherent FMV frames, including
    `ridge-004.png` and `ridge-008.png`.

2026-05-28 continuation:

- Fixed the current Rage Europe intro decoder overrun. The root cause was not
  the software bitstream terminator itself: the game was entering decoder
  callback `0x8006CE78` after the first sector of a multi-sector STR group.
  At the first bad decode, queue entry 0 was already promoted even though its
  sector info was `sector_count=6, sector_index=0`; the decoder then consumed
  an incomplete frame and ran until an accidental late `0x7C1F` marker after
  crossing the 2 MB RAM mirror.
- Added a scoped guard for Rage's CD-ROM DMA callback during the Europe intro
  whole-sector stream from LBA 304. The callback at `0x8006CE78` now returns
  immediately until the current queue entry is sector 0 and all sectors in its
  group are present/state 3. Once the group is complete, the real callback is
  allowed to run and the foreground decoder can consume a complete frame.
- Added CPU specs covering both paths: incomplete Rage DMA groups skip the
  callback, complete groups execute it.
- Verification:
  - Focused CPU spec passed: `29 runs, 34 assertions, 0 failures`.
  - Full suite passed: `341 runs, 859 assertions, 0 failures`.
  - Rage Europe 800M-cycle smoke now stays out of the corrupted low-vector
    trap. It reaches repeated 24-bit 320x240 intro state with
    `vec=3C1A0000` still intact; the earlier 200M `0x80000080/84` failure is
    gone in this window.
  - Longer Start-tapping probes after this fix:
    - `bin/_ridge-boot` to 2.8B cycles with Start toggled from 1.0B stayed
      stable and produced visible intro screenshots under
      `conformance-shots/rage-eu-start-after-dma-guard/`, including
      `ridge-014.png`.
    - A controller-poll counter run to 2.8B shows Rage is polling the pad
      during the later intro (`~1.6K polls per 200M-cycle chunk`, all seeing
      Start pressed after 1.0B). The run still did not prove a title/menu skip
      by 2.8B, so the original Start-to-skip complaint is now a separate input
      semantics/game-state issue rather than being blocked by the old stream
      decoder crash.
  - Fixed Rage Europe's direct pad-buffer Start decoding. DuckStation confirms
    that the controller serial protocol still returns button bytes low then
    high, but Rage's `PadInitDirect` buffer reader treats bytes `+2/+3` as
    high then low. The existing once-per-frame direct-buffer shim wrote the
    right order, but the BIOS serial poll immediately overwrote the buffer with
    raw serial order (`00 41 F7 FF`), so Rage decoded Start as `0x0800`
    instead of `0x0008`. The direct-buffer shim now normalizes the buffer after
    each device batch as well, leaving SIO serial behavior unchanged.
  - Verification for the pad-buffer fix:
    - Focused emulator spec passed: `2 runs, 3 assertions, 0 failures`.
    - Focused SIO0 spec passed: `20 runs, 53 assertions, 0 failures`.
    - Full suite passed: `341 runs, 859 assertions, 0 failures`.
    - Rage Europe live buffer probe at 1.1B cycles with Start held from 1.0B:
      `pad_ptr=801E403C bytes=00 41 FF F7 mask=0008`, with the old wrong
      `0x0800` bit no longer set.
    - Long Rage Europe Start smoke to 2.8B cycles with Start held from 1.0B
      reached 15-bit 320x240 mode after leaving the FMV path. Screenshots
      under `conformance-shots/rage-eu-start-after-pad-normalize/` show the
      title screen with the full Rage Racer logo at `ridge-012.png`, then an
      in-engine attract/race scene at `ridge-014.png`.
- Fixed a DuckStation-backed GPU primitive coordinate mismatch. GPU drawing
  primitive positions are 11-bit signed fields, and variable rectangle
  dimensions are masked to the VRAM width/height fields; the Ruby renderer was
  treating primitive positions and variable sprite sizes as full 16-bit
  fields. This can misplace or stretch textured sprites when high bits are
  present in command words.
- Added GPU regression specs for 11-bit rectangle positions and masked
  variable rectangle sizes.
- Verification for the GPU coordinate fix:
  - Focused GPU regression spec passed:
    `14 runs, 41 assertions, 0 failures`.
  - Focused GPU spec passed: `15 runs, 37 assertions, 0 failures`.
  - Full suite passed: `345 runs, 865 assertions, 0 failures`.
  - Rage Europe smoke to 2.4B cycles with Start held from 1.0B reached the
    same 15-bit title path; `conformance-shots/rage-eu-gpu-vertex-coords/ridge-012.png`
    shows the full Rage Racer logo and `PRESS START`.
- Fixed MDEC 24-bit output byte order against DuckStation's `CopyOutBlock`.
  DuckStation's MDEC `block_rgb` stores R/G/B in low-to-high bytes and the
  24-bit FIFO copy-out emits RGB byte order; the Ruby packer was emitting
  BGR, which a gray-only test did not catch.
- Added an MDEC spec with a non-gray chroma block so channel swaps are visible.
- Verification for the MDEC 24-bit byte-order fix:
  - Focused MDEC spec passed: `11 runs, 21 assertions, 0 failures`.
  - Full suite passed: `346 runs, 867 assertions, 0 failures`.
  - Rage Europe smoke to 1.6B cycles remained stable in the 24-bit FMV path;
    `conformance-shots/rage-eu-mdec-rgb-order/ridge-008.png` shows a visible
    decoded frame.
- Fixed MDEC RLE block termination. DuckStation ends a block once the RLE run
  advances to coefficient 63 or beyond; the Ruby decoder only ended on
  explicit `0xFE00` or index overflow, so streams using values like `0xF800`
  as the final coefficient over-consumed the next block header. The
  ps1-tests `mdec/step-by-step-log` case exposed this as a 1536-byte decode
  where 2048 bytes were expected.
- Added a focused MDEC spec for coefficient-63 termination.
- Verification for the RLE termination fix:
  - Focused MDEC spec passed: `12 runs, 22 assertions, 0 failures`.
  - ps1-tests `mdec/4bit`, `mdec/8bit`, and `mdec/step-by-step-log` all
    matched their `psx.log` marker expectations.
  - Direct decode of `step-by-step-log/symbols.mdec` now produces
    `512` output words / `2048` bytes.
  - Full suite passed: `347 runs, 868 assertions, 0 failures`.
- Fixed R3000A load-delay timing. Loaded values now commit after the
  immediately following instruction executes, so that instruction still sees
  the old register value. Writes to the same register cancel the pending load.
- Matched DuckStation's `lwl`/`lwr` load-delay merge behavior: a consecutive
  unaligned load pair now merges through the pending load-delayed value for
  the same target register.
- Added CPU specs for the delayed `lw` visibility, pending-load cancellation,
  and consecutive `lwr`/`lwl` merge case. Save states now preserve the new
  pending load-commit slot.
- Verification:
  - Focused CPU/savestate specs passed:
    `27 runs, 30 assertions, 0 failures`.
  - Full suite passed:
    `339 runs, 855 assertions, 0 failures`.
- Rage Europe status:
  - The CPU load-delay fixes are correct accuracy work but do not resolve the
    current Rage intro blocker. A 500M-cycle smoke still reaches the same
    early stream decoder failure: by 200M the low exception vector is
    overwritten with stream-looking data (`0x1D842FE7...`) and PC is stuck at
    `0x80000080/84`.
  - Re-testing the old scoped Rage intro IRQ policy on the current tree also
    did not restore the title path; queue entries are already state `2` and
    the decoder still overruns. The remaining lead is still the software STR
    bitstream decode/terminator path or another CPU/data-path issue, not pad
    Start handling.
  - A focused CD DMA trace shows the suspect source bytes at `0x800FF6EC`
    are direct whole-sector STR payload bytes from disc, not a later RAM
    scribble. The repeating `02 28...` pattern seen in early probes exists in
    the disc stream itself for some sectors; later sectors at the same ring
    address contain varied payload bytes such as `41 95 84 2F...`.
  - A decoder trace shows Rage does eventually take the `0x7C1F` terminator
    path, but far too late: at the observed hit, `src=0x8019C796` and
    `out=0x8020BF70`, so the decoder has already crossed the 2 MB RAM mirror
    and corrupted low RAM/stack state. This reinforces that the blocker is
    "decoder consumes the wrong/too much stream data before terminator", not
    that the terminator branch is never implemented.
  - Rejected probes from this continuation:
    - Prefer cache-isolated instruction words over nonzero RAM fetches. This
      either masks loaded game code when cached zero-fill is present or, when
      limited to nonzero cache words, does not change the Rage overrun because
      the low vector words were not captured as nonzero isolated-cache writes.
    - Treat Rage's `k0` low-vector trampoline as unusable and force installed
      callback fallback. This regresses before the intro stream, matching
      earlier notes that the loader still needs the real/vector path.
    - Force CD-ROM 2x timing down to 1x. The failure still reaches the
      corrupted low-vector path, so simple sector cadence is not the root
      fix.

2026-05-27 sixth update:

- Additional continuation after the sixth update:
  - Fixed MDEC control writes with reset+DMA enable bits. DuckStation applies
    the DMA enable bits from the same MDEC1 write after soft reset; Ruby now
    does the same instead of returning immediately after reset.
    Commit: `8d0cc8f Apply MDEC DMA enables after reset`.
  - Added CD-ROM Forward/Backward command handling. Commands `0x04`/`0x05`
    now validate as zero-parameter commands, return not-ready INT5 unless
    CDDA playback is active, and ACK while playing, matching DuckStation's
    command path. Commit: `09e9f61 Handle CDROM scan commands`.
  - Added CD-ROM ReadT command handling. Command `0x12` now requires one
    session parameter, rejects session zero, ACKs session 1, and completes
    later with INT2, matching DuckStation's single-session path.
    Commit: `db33a29 Handle CDROM ReadT command`.
  - Completed CD-ROM command parameter-count validation for the remaining
    DuckStation table entries: SetClock, GetClock, Reset, GetQ, and VideoCD.
    Unsupported commands still return invalid-command after valid arity, but
    wrong arity now returns incorrect-number-of-parameters first.
    Commit: `47f052f Validate remaining CDROM command counts`.
  - Added specs for the valid-arity unsupported CD-ROM command path. GetClock,
    GetQ, and VideoCD now have explicit coverage that they return
    invalid-command after passing their DuckStation-backed parameter counts.
    Commit: `cfbcaa8 Spec unsupported CDROM command arity`.
  - Added SIO RX interrupt behavior. JOY_CTRL bit 11 now raises
    IRQ_CONTROLLER when a response byte enters the RX FIFO, matching
    DuckStation's `RXINTEN` path. Commit: `227f0cc Raise SIO RX interrupts`.
  - Added SIO TX interrupt behavior. JOY_CTRL bit 10 now raises
    IRQ_CONTROLLER when a transmit byte is accepted, matching DuckStation's
    `TXINTEN` path. Commit: `347c964 Raise SIO TX interrupts`.
  - Tightened SIO TX interrupt ordering. JOY_DATA writes now raise TXINTEN
    IRQs even when SELECT/TXEN do not allow a transfer, matching DuckStation's
    data-register write path. Commit:
    `6f1aad7 Trigger SIO TX interrupts on data writes`.
  - Split SIO TX interrupts from later serial receive completion. TXINTEN
    still fires on JOY_DATA writes, but the response byte and RX/ACK side
    effects now arrive after a short transfer delay instead of immediately.
    Commit: `04ab2ed Delay SIO receive completion`.
  - Hardened the installed-callback IRQ fallback for corrupted low exception
    vectors. A recognizable `j/jal` vector or Rage's `k0` trampoline still
    vectors normally; all-zero or garbage vectors use the installed callback
    table. Commit: `bdb12fa Handle corrupted IRQ vectors`.
  - Fixed MDEC signed colour output. 24-bit/15-bit colour conversion now
    honors command bit 26: signed output no longer receives the unsigned
    +128 bias. Commit: `c412ed7 Honor signed MDEC colour output`.
  - Fixed MDEC 15-bit colour packing. RGB888 channels now round to 5-bit
    with `+4 >> 3`, matching DuckStation's newer path, instead of truncating.
    Commit: `d9463fd Round MDEC 15-bit colour output`.
  - Fixed CD-ROM GetlocP before any sector read. With media present, GetlocP
    now synthesizes current SubQ instead of returning a not-ready INT5,
    matching DuckStation's `UpdateSubQPosition/EnsureLastSubQValid` path.
    Commit: `1d8d946 Return CDROM GetlocP before first read`.
  - Verification:
    - After signed MDEC colour output: full suite passed
      `316 runs, 796 assertions, 0 failures`.
    - After rounded MDEC 15-bit output: full suite passed
      `317 runs, 797 assertions, 0 failures`.
    - After CD-ROM GetlocP fallback: full suite passed
      `317 runs, 797 assertions, 0 failures`.
    - After MDEC reset+DMA enable: full suite passed
      `318 runs, 798 assertions, 0 failures`.
    - After CD-ROM Forward/Backward: full suite passed
      `320 runs, 805 assertions, 0 failures`.
    - After CD-ROM ReadT: full suite passed
      `323 runs, 815 assertions, 0 failures`.
    - After remaining CD-ROM command counts: full suite passed
      `326 runs, 824 assertions, 0 failures`.
    - After SIO RX interrupt behavior: full suite passed
      `327 runs, 826 assertions, 0 failures`.
    - After SIO TX interrupt behavior: full suite passed
      `328 runs, 828 assertions, 0 failures`.
    - After SIO TX data-write ordering: full suite passed
      `329 runs, 830 assertions, 0 failures`.
    - After unsupported CD-ROM valid-arity specs: full suite passed
      `332 runs, 839 assertions, 0 failures`.
    - After delayed SIO receive completion: full suite passed
      `333 runs, 842 assertions, 0 failures`.
    - After corrupted IRQ vector handling: full suite passed
      `336 runs, 851 assertions, 0 failures`.

- Current Rage Europe input/title blocker:
  - The Start issue is still not proven fixed. A 2.9B-cycle scripted-Start run
    after the SIO receive-delay fix still produced RGB-black screenshots.
  - The immediate failure now reproduces earlier than title input: by 400M
    cycles Rage has taken an arithmetic-overflow exception in the MDEC/Huffman
    decode loop at `EPC=80064760` (`add $t0,$t0,$a2`). The low exception vector
    is corrupted with stream-looking data, so without a real instruction-cache
    model the game cannot run its normal exception handler.
  - This points back to stream/decode data correctness rather than keyboard
    Start mapping: the pad path is active enough to print Namco's
    `PS-X Control PAD Driver  Ver 3.0`, but Rage does not reach a stable title
    input point in the current tree.

- Added DuckStation-backed SPU DMA request status behavior:
  - `SPUSTAT` bits 7/9 now report a DMA write request when SPUCNT transfer
    mode is DMA write and the simplified transfer FIFO is empty.
  - Leaving DMA transfer modes clears the DMA request bits.
  - Commit: `8d49fe4 Report SPU DMA write requests`.
- Tightened digital pad command handling against DuckStation:
  - After the initial `0x01` select byte, the digital pad now only
    acknowledges command `0x42`. Unknown controller commands return `0xFF`
    and end the transfer instead of continuing as a normal pad read.
  - Commit: `b019264 Reject unknown digital pad commands`.
- Fixed a GPU texture/CLUT raster bug:
  - 4-bit/8-bit CLUT lookups now wrap horizontally within the VRAM row.
    DuckStation explicitly wraps CLUT loads when an 8-bit palette crosses
    x=1023; the old Ruby sampler spilled into the next row, which can produce
    wrong-colour/wrong-half texture artifacts for palettes near row end.
  - Commit: `fa3061e Wrap GPU CLUT lookups within row`.
- Verification:
  - After the SPU change, full suite passed:
    `313 runs, 790 assertions, 0 failures`.
  - After the SIO change, full suite passed:
    `314 runs, 793 assertions, 0 failures`.
  - After the GPU CLUT wrap change, full suite passed:
    `315 runs, 794 assertions, 0 failures`.
- Remaining Rage-specific caveat:
  - The Rage Europe Start-to-skip-intro complaint has not been proven fixed.
    The pad command change is accuracy work, not yet proof that intro skip
    works.
  - The title/logo texture issue may be helped by the earlier texture-flip
    fix and this CLUT wrap fix, but it still needs a Rage screenshot smoke
    run to verify.

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
