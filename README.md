# Bismuth

A cycle-accurate NES emulator in Swift, with a Metal renderer and a libretro core.

Requires Swift 6 (Xcode 16+). No ROMs are included.

## Install

```swift
.package(url: "https://github.com/StephenDev0/Bismuth.git", branch: "main")
```

Products: `NESCore`, `NESMetal`, `NESAchievements`.

## Usage

```swift
import NESCore

let nes = try NESConsole(rom: romBytes)
nes.setButtons([.start], player: 0)
nes.runFrame()
nes.renderARGB(into: pixels)      // 256x240
let audio = nes.drainAudio()      // stereo Int16, 48 kHz
let state = nes.saveState()
try nes.loadState(state)
```

```swift
import NESMetal

NESScreen(console: nes)           // SwiftUI view; runs and draws one frame per refresh
```

## libretro core

```sh
Scripts/build-libretro.sh         # macOS, iOS, iOS simulator and tvOS builds in dist/
```

## Command line

```sh
swift run -c release bismuth-cli run game.nes --frames 600 --png shot.png
```

## Tests

```sh
swift test
```

## License

[Bismuth License (MIT, Non-Commercial)](LICENSE). Not affiliated with Nintendo.
