# Repository Guidelines

Purrthrough is a small, native macOS menu-bar app (Swift 6, macOS 15+) that plays an
audio input through the current output device. Keep it lightweight: Apple frameworks
plus Sparkle, nothing else.

## Layout

- `Sources/PurrthroughCore`: hardware-independent logic (lock-free FIFO, drift
  control, input selection). Covered by `swift test`.
- `Sources/PurrthroughApp`: Core Audio capture, AVAudioEngine playback, the
  controller that reconciles state with hardware, the menu and Sparkle.
- `project.yml`: XcodeGen source of truth. Run `xcodegen generate` after changing it
  and commit the regenerated project. Entitlements are declared there, because
  XcodeGen rewrites `Config/Purrthrough.entitlements`.

## Audio rules

- Never touch `AVAudioEngine.inputNode` or the default input device. Opening a
  Bluetooth headset's microphone forces the headset into call mode.
- Realtime callbacks (capture and the source node) must not allocate, lock, log or
  call into Swift concurrency.
- Funnel every state change through `PlaythroughController.reconcile()`. Errors
  surface in the menu status and retry; never swallow them.

## Checks

```sh
swift test
python3 -B -m unittest discover -s scripts/tests -v
xcodegen generate && xcodebuild -project Purrthrough.xcodeproj -scheme Purrthrough CODE_SIGNING_ALLOWED=NO build
```

Hardware behaviour (hot-plugging, Bluetooth switching, sleep and wake) needs a manual
test on a real Mac. The app logs fill level, rate and dropouts every 10 seconds:
`log stream --info --predicate 'subsystem == "com.firefungames.purrthrough"'`.

## Releases

Read `docs/releases.md`. Publish only after owner approval. Keep all Apple and
Sparkle keys out of the repository and CI.
