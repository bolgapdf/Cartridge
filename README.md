# Cartridge

A Game Boy and Game Boy Color emulator for iPhone, iPad, and Mac, written
from the processor up in Swift. No existing emulator code — the CPU,
graphics chip, and sound hardware are each simulated independently.

## What it does

- Full Game Boy and Game Boy Color support: colour palettes, banked work
  RAM, H-blank VRAM transfer, double-speed mode.
- Four-channel sound, mixed through the hardware's own panning and
  volume and output through a lock-free audio buffer.
- Save states, standard battery saves, and a library with custom cover
  art and iCloud sync across devices.
- Five visual themes, touch controls, a hardware keyboard, and on-screen
  clip capture to GIF.

## Accuracy

Verified against the public hardware test suites the emulator community
uses to check correctness: 500,000 individual instruction test cases
passed, and pixel-for-pixel identical output against a published
reference on the standard graphics-accuracy tests. The full suite runs
in about seventeen seconds.

![Accuracy comparison against a published reference render](docs/accuracy.png)

## Dowser

Cartridge can open a local network port that streams snapshots of a
running game's memory and accepts live edits to it, gated behind a
setting that's off by default. [Dowser](https://github.com/bolgapdf/Dowser)
is a separate tool, also built from scratch, that connects to this port
to search that memory and freeze values live while the game runs.

## Built with

Swift, SwiftUI, for iOS and macOS.

## Running it

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
./scripts/fetch-tests.sh
./scripts/fetch-roms.sh
xcodebuild test -scheme Cartridge_macOS -destination 'platform=macOS'
```

No ROMs are included.
</content>
