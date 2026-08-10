# Cartridge

**A Game Boy and Game Boy Color emulator for iPhone, iPad, and Mac — built
entirely from scratch in Swift.**

No third-party emulation engine, no existing emulator code adapted into
Swift. Every part of the original hardware — the processor, the graphics
chip, the sound chip — is simulated from the ground up, closely enough that
real, unmodified commercial games run correctly.

## Why "closely enough" is the hard part

Anyone can write an emulator that boots a game they own — that's the easy
80%. The last 20% is games that quietly depend on quirks and timing details
of the original 1989 chip that most emulators approximate rather than get
exactly right, which shows up as small glitches: audio that's a beat off,
a visual effect that renders wrong for one frame, a game that works until
one specific level.

The retro-hardware community has built public test suites specifically to
catch this kind of thing — the same ones used to validate professional and
open-source emulators. This project is run against all of them:

| Check | What it's really testing | Result |
| --- | --- | --- |
| Full instruction-set test | Every single operation the processor can perform, checked one at a time against a reference | **500,000 test cases passed** |
| Hardware timing tests | Whether the emulator's sense of time matches real silicon down to the individual clock cycle | **Passed** |
| Pixel-accuracy tests | Whether a full frame of graphics, rendered under deliberately awkward conditions, matches real hardware exactly | **Every one of 23,040 pixels correct** |

That last one is worth dwelling on: two independent renders of the same
test frame — this emulator's, and one published by another well-known
project — are pixel-for-pixel identical.

![Side-by-side accuracy comparison](docs/accuracy.png)
*Three renders of the same graphics-accuracy test, side by side. Structurally identical.*

## What it does

- Plays both original Game Boy and Game Boy Color games, in full color
  where supported.
- Real four-channel sound, not an approximation.
- Save states (multiple slots, plus an automatic one, so quitting a game
  never costs you progress) alongside standard battery saves that work the
  same way the original cartridges did.
- A proper library: your own cover art (or an auto-captured one), five
  visual themes styled after real handhelds and desktop machines, and games
  that sync across your devices via iCloud.
- Touch controls, a hardware keyboard, and on-screen clip capture to GIF.

## A companion project: Dowser

Cartridge can optionally open a local network port that streams out
snapshots of a running game's memory and accepts live edits to it. I built
a second, separate application — **[Dowser](https://github.com/bolgapdf/Dowser)**
— that connects to this port to search that memory in real time and pin
down exactly which byte controls something you care about (health, money,
which monster you're about to run into), then freeze it live while the
game keeps running. The two projects only ever talk over a small protocol
I designed for the purpose — Cartridge doesn't know anything about how
Dowser works, and vice versa.

## The interesting bug

At one point a performance profile showed the renderer suddenly getting
dramatically cheaper — great news, in theory. It turned out to be cheaper
because it had quietly stopped drawing anything at all. The lesson that
stuck: a performance number on its own proves nothing was slow, not that
anything was correct — every optimization since has been checked against
the accuracy suites above, not just a stopwatch.

## Built with

Swift, SwiftUI, for iOS and macOS.

## Getting it running

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
./scripts/fetch-tests.sh   # downloads the accuracy test suites
./scripts/fetch-roms.sh
xcodebuild test -scheme Cartridge_macOS -destination 'platform=macOS'
```

No ROMs are included, or ever will be — you add your own.
</content>
