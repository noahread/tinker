# tinker — agent guide

macOS menu bar app that turns the Teenage Engineering EP-2350 "ting" into a
smart push-to-talk controller: squeezing the handle drives the frontmost
app's own dictation shortcut (Claude ⌘D, Codex, …), falls back to a running
transcription app (MacWhisper, Handy), and finally to built-in on-device
dictation. Fork of [tutorintelligence/tingle](https://github.com/tutorintelligence/tingle)
(MIT). Swift (SwiftPM) on the Mac + a MicroPython payload that runs on the
device itself. See DESIGN.md for architecture and the chirp protocol;
README.md for user-facing docs.

Upstream remote: `upstream` → tutorintelligence/tingle. Fetch it with
`git fetch --no-tags upstream`: tingle's tags (v0.1.0 … v0.14.4) collide
with tinker's own release tags. Module/target names
(`TingleCore`, `tingle`, `tingle-tests`), `Log.subsystem`, and the config
folder `~/Library/Application Support/tingle` are deliberately kept as
upstream's so `git merge upstream/main` stays cheap. Only user-facing
strings and the bundle id (`AppIdentity.bundleID`) are tinker's.

## Build, test, run

```sh
swift build                      # compile
swift run tingle-tests            # Swift unit tests (no XCTest: bare CLT works)
python3 tools/test_payload.py    # device event-engine unit tests
scripts/bundle.sh                # assemble dist/tinker.app (ad-hoc unless CODESIGN_IDENTITY set)
swift run tingle                  # run the menu bar app (dev)
scripts/dev.sh                   # quit the installed app, build + run the dev binary
```

CI (.github/workflows/ci.yml) runs all of the above plus a payload-sync
check. Both test suites must pass before any commit that touches routing,
detection, dictation, or the device payload. Add a regression test with
every bug fix.

## Routing (tinker's addition)

- `RouteResolver.swift` is pure: frontmost bundle id + running bundle ids +
  config → `Route`. `RouteSession` remembers the route chosen at squeeze so
  the release closes the SAME app's toggle even if focus moved. Keep both
  AppKit-free and covered by `Tests/tingle-tests/RouteResolverTests.swift`.
- Lifecycle invariant from upstream still holds: a release ALWAYS releases
  held keys and stops built-in dictation before any route `up` action.
- Config: `[apps."<bundle id>"]` tables merge per app with the defaults;
  a user `[[fallback]]` array replaces the default list wholesale; "builtin"
  is simply `[mappings] triggerDown/triggerUp`.
- Settings window (`Settings.swift`, `SettingsWindow.swift`): saves
  `settings.json` and layers `AppSettings.tomlOverlay()` as a THIRD config
  layer that owns `apps` and `fallback` outright (`TingConfig.parse(defaults:
  user:settings:)` drops the lower layers' copies). First open seeds from
  the live config so nothing changes until the user edits. Nothing is
  written until an edit.
- Log stream for live debugging:
  `log stream --predicate 'subsystem == "com.tutorintelligence.tingle"' --info --debug`
  Note: info/debug lines do NOT persist for `log show` — stream to a file.
- Only one tinker/tingle may run at a time (flock in App Support).

## Device payload rules (device/tingle_main.py)

- `device/tingle_main.py` is the source of truth;
  `Sources/TingleCore/Resources/tingle_main.py` must stay byte-identical
  (CI enforces). Sync with `cp` after every edit.
- The device loads `main.py` from its FAT disk at BOOT ONLY (fw 1.0.4):
  every payload change needs Flash EP (menu) + a device power cycle
  (button above the USB-C port, then push the handle).
- NEVER call `fx.load_preset` / `fx.preset*` on a live device while a
  voice is playing — it wedges the audio engine, then the whole device.
- The device has no batteries by default: unplugging USB power-cycles it.
  On batteries it sleeps after 5 min idle (beacons stop — that's sleep,
  not a crash; squeeze the handle to wake).
- Exceptions in the payload callback are swallowed by the crash recorder
  (falls back to stock, writes /fat/tingle_crash.log). Tests must call
  `_tingle_cb` directly to surface errors; check the crash log on-device
  when the engine goes silent.
- Firmware update ritual (TE readme, implemented by "Upgrade ting
  firmware…"): lower lid off, USB attached, HOLD the handle the whole
  time, and while holding, DOUBLE-CLICK the small button above the USB
  port -> "TING BOOT" volume appears; drop the .uf2 there. NOT the
  power-ritual button dance. The double-click must be two RAPID presses
  (mouse-double-click speed) — two deliberate presses just power-cycle
  (cost a failed flow, 2026-08-05).
- Never present NSAlert.runModal() — a modal session parks the main run
  loop and freezes dictation/serial/menu while open. Use FloatingAlert.
- Serial REPL access (`/dev/cu.usbmodemEPTXP*`, 115200): `\r\x03\x03`
  grabs the REPL. Never send Ctrl+D (soft reset re-enumerates USB; a
  battery-less unit stays down until the power ritual). tingle holds the
  port exclusively — kill it before REPL diagnostics.

## Hardware facts that bite

- Engine tick rate ~61 Hz. `spl.trigger(-1, slot, False)` cannot stop a
  oneshot sample; sequencing relies on gaps.
- The trigger has TWO sensors: a tactile switch (`ui.sw(4)`, trips ~2%
  travel, huge/sticky release hysteresis) and an analog shaft
  (`ui.handle_raw()`, 0–1). Fast shallow clicks move the switch but not
  the shaft. The payload fuses both (debounce + shaft-trust + stuck-latch).
- The Cubilux HLMS-C4 exposes MIC IN and Line IN input devices; ultrasonic
  chirps bleed across jacks. Device ranking must prefer "line in" names
  and the beacon scanner audits the top-ranked jack before locking.
- SIGNALING (DESIGN.md "Signaling protocol"): the slots hold 25ms coded
  chirp symbols from SymbolSet.swift; every event is a 4-symbol
  Reed-Solomon codeword (distance 3, single-error correction),
  matched-filter decoded by SymbolDetector.swift. SymbolSet is the
  air-gap contract: change it and the device must be re-flashed. The
  decoder requires exactly 48kHz input. Pilot lock: NO events until 3
  periodic level-consistent beacons; sleep unlocks; single-beacon fast
  re-lock. The payload must stay pure ASCII (serial-write deploys drop
  non-ASCII; also the em-dash rule).
- Chirp levels depend on BOTH the WAV amplitude and the firmware's
  output mixer: fw 1.0.5-1.0.8 rebalanced levels (0.30-amplitude tones
  that nearly clipped 1.0.4 landed at -35dBFS on 1.0.8 — phantom
  presses, laggy triggers). Symbols generate at 0.95. When recording
  the line-in with ffmpeg for diagnosis: it captures STEREO —
  deinterleave before FFT, or the signal vanishes (cost an hour,
  2026-07-11).
- fw <= 1.0.5 reloads FACTORY samples after battery sleep (TE fixed in
  1.0.6), silencing the chirp protocol while the engine keeps beaconing —
  audible TE samples every 2s = this. The payload self-heals (tick-gap
  wake detection + slow rotation reload). "Upgrade ting firmware…" in the
  menu flashes TE's pinned-latest UF2 (FirmwareUpgrader.swift: download →
  guided BOOTSEL re-plug → copy .uf2 → re-flash payload); fw 1.0.6+ fixes
  the sleep clobber at the source. The exact fw version is NOT detectable
  (bcdDevice only says 1.00), so the flow flashes unconditionally —
  harmless when already current. Payload-on-1.0.8 still needs one live
  verification.
- spl.load_wav takes (slot, OPEN BINARY FILE, playmode) — passing a path
  string wedges the VM (needs the power ritual). Reference for the whole
  device API: the stock /rom/main.py inside TE's firmware zip.
- Beacons carry handle state on both transports ("EVT beacon 0|1" over
  serial; (1,3)/(3,1) chirp pairs over audio). A LEGACY stateless serial
  beacon line must never be read as "released" (regression: synthesized
  releases killed USB dictation) — healing requires the state token.

## Mac-side invariants

- SpeechTranscriber needs `[.volatileResults, .fastResults]` or output
  arrives in multi-second clumps. Never type inline in the results loop —
  the typing worker converges on the latest hypothesis.
- TranscriptTyper corrections are bounded to the volatile region; any
  external typing during dictation must freezeVolatile() first.
- TCC (mic/accessibility) keys off the code signature: release builds are
  Developer ID-signed so grants persist across updates; ad-hoc .app
  rebuilds re-prompt every time. The dev binary attributes permissions to
  the invoking terminal instead.
  PermissionsMonitor owns the UX: "!" icon badge, fix-it menu items, launch
  prompts, and a tccutil-reset repair for the stale-Accessibility-row case.

## Captured audio rule

NEVER commit audio recorded from the ting (or any capture device)
without Noah's explicit per-file approval — the ting is a microphone
with passthrough, so "sensor data" recordings can carry his voice.
Stage candidates in a folder, `open` it in Finder for them to inspect,
and prefer hard FFT-masked (>15kHz-only) versions for fixtures.

## Contribution flow and releases

Commit directly on `main` or on short-lived branches; Conventional Commit
subjects (`feat:`, `fix:`, `chore:`, …) are preferred but not enforced.

- `scripts/install.sh` builds, installs to /Applications and relaunches.
  `scripts/bundle.sh` auto-detects a signing identity (Developer ID, else
  Apple Development, else ad-hoc; `CODESIGN_IDENTITY=-` forces ad-hoc).
- Releases: push a tag `vX.Y.Z` → `.github/workflows/release.yml` builds,
  zips and publishes a GitHub Release. Ad-hoc signed unless the Developer
  ID / notarization secrets exist (see the workflow header).
- Flash EP writes `tinker.json` (firmware version + payload SHA-256) to
  TINGDISK; `Flasher.adoptionOnDisk` reads it on any Mac so a set-up ting
  is adopted into Prefs without a second firmware ritual. Restore stock
  removes it.
