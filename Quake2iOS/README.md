# Quake 2 iOS Port

An iOS port of id Software's Quake II, built with Metal rendering and touch controls.

## Requirements

- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 16.0+ (ARM64)
- Quake II game data (PAK files)

## Setup

1. Install XcodeGen if you don't have it:
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   cd Quake2iOS
   xcodegen generate
   ```

3. Place your Quake II game data (`pak0.pak`, etc.) in `Assets/baseq2/`.

4. Open `Quake2iOS.xcodeproj` in Xcode, set your development team, and build.

> The `.xcodeproj` is generated from `project.yml` and is gitignored. Always regenerate it after cloning.

## Build (command line)

```bash
cd Quake2iOS && xcodegen generate && xcodebuild \
  -project Quake2iOS.xcodeproj \
  -scheme Quake2iOS \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build
```

## Architecture

```
Quake2iOS/
├── UI/          — Swift: GameViewController, TouchControlsView, GameControllerManager
├── Renderer/    — Metal renderer (replaces OpenGL ref_gl)
│   └── Shaders/ — Metal shader files
├── Platform/    — sys_ios, snd_ios, in_ios (Sys/SNDDMA/IN implementations)
├── Engine/      — Prefix header and iOS-specific engine config
├── Bridging/    — C↔Swift bridging header
└── Assets/      — Game data (baseq2/)
```

The original Quake II engine sources (`client/`, `server/`, `qcommon/`, `game/`) are compiled directly from the parent directory. The game module is statically linked (`GAME_HARD_LINKED=1`) rather than loaded as a DLL.

## Key Design Decisions

- **Metal** replaces the OpenGL renderer, implementing the full `refexport_t` interface
- **AVAudioEngine** handles audio via a DMA ring buffer approach
- **Touch controls** with virtual joysticks and buttons, plus MFi/DualSense gamepad support
- **Single-player only** — no networking code
