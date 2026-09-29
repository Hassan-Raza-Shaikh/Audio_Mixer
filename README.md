# Aura

A native macOS per-app audio mixer and screen recorder.

Aura gives every app its own volume, mute, stereo balance and output device —
the per-app audio control macOS doesn't offer on its own — and it records the
screen **with the sound you actually hear**, which a normal macOS screen
recording can't do.

> macOS 26 or later · Swift 6 · App Sandbox · universal (Apple silicon + Intel).
> Lives in the menu bar, with an optional mixer window.

## Features

- **Per-app mixer** — volume, mute and balance for each app, from the menu bar
  or the mixer window. Untouched apps aren't processed at all.
- **Per-app output** — send one app to your speakers and another to headphones.
  "System Default" follows macOS when you plug in or unplug a device.
- **Works with browsers and Electron apps** — Aura controls an app's whole audio
  process tree (Chrome, Edge, Teams, Discord, Spotify, … play sound from helper
  processes; Safari from WebKit's GPU process).
- **Screen recording with audio** — one click records the screen and everything
  you hear into a single `.mov` (H.264/HEVC + AAC). Toggle audio on or off.
- **App audio recording** — save a single app's audio to a WAV file.
- **Spatial soundstage** — drag apps on a 2D stage to set volume and balance.
- **Launch at login**, remembered recording folders, full VoiceOver support.

## Where files are saved

| What | Default location | Change it |
|------|------------------|-----------|
| Screen recordings | `~/Movies/Aura Screen Recordings/` | Folder button next to Record, or Settings |
| App audio recordings | `~/Music/Aura Recordings/` | Settings |

Chosen folders are remembered with security-scoped bookmarks (App Sandbox).

## Permissions

Both live under **System Settings → Privacy & Security → Screen & System Audio
Recording**. Aura asks only when a feature first needs them.

| Permission | Needed for | Asked when |
|------------|------------|------------|
| **System Audio Recording** | Controlling an app's volume/output, recording app audio, audio in screen recordings | You first adjust an app |
| **Screen Recording** | Screen recordings | You first press Record Screen |

Aura doesn't use the microphone. If adjusted apps go quiet because access was
denied, Aura shows a banner with **Open Settings** and **Try Again**. Audio is
processed on your Mac and never leaves it.

## Building

[XcodeGen](https://github.com/yonghyun/XcodeGen) generates the Xcode project
from `project.yml` (the `.xcodeproj` isn't checked in).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer -configuration Debug build
```

### Signing

`Signing.xcconfig` signs ad-hoc by default so a fresh clone always builds.
Override per machine in `Local.xcconfig` (git-ignored; see
`Local.xcconfig.example`):

- **Local development** — run `./scripts/setup-local-signing.sh` once. It creates
  a stable self-signed identity so macOS privacy grants survive rebuilds (ad-hoc
  signatures change every build, so grants would reset).
- **App Store / TestFlight** — set your Apple Developer Team ID in
  `Local.xcconfig` (Option B in the example). See [APP_STORE.md](APP_STORE.md).

## How it works

**Per-app control.** The first time you adjust an app, Aura creates a Core Audio
*process tap* (`CATapDescription`) over all of that app's audio processes, set to
mute them at the hardware while tapped. The tap and your chosen output device
are combined in one private aggregate device, so every IO cycle hands Aura the
app's samples and the output buffer together: it applies volume/balance (with
click-free ramping) and writes straight to the device — no extra buffering, and
clock drift is compensated by Core Audio. "Reset to Normal Audio" removes the
tap and hands the app back to macOS.

**Screen recording.** ScreenCaptureKit provides the video; audio comes from a
separate global tap. Taps see an app's audio *before* the hardware mute, so a
plain system capture would contain both an adjusted app's original and Aura's
copy (which partly cancel). The recording tap therefore excludes the apps Aura
is routing and includes Aura's own output — exactly what you hear — and is
rebuilt whenever you adjust or reset an app mid-recording. Silent stretches are
filled with silence so the audio track always spans the whole video, and the
movie ends exactly when you press Stop, even if the screen was static.

## Project layout

```
Sources/
  AudioMixerApp.swift             App entry: menu bar extra, mixer window, Settings
  Audio/
    AudioHAL.swift                Typed Core Audio property helpers, audio-process list
    AudioDeviceManager.swift      Output devices, default output, change notifications
    AppAudioRoute.swift           One app's tap + aggregate device + real-time mixing
    AudioRouter.swift             Owns live routes and per-app recorders
    SystemAudioCapture.swift      "What you hear" tap used for screen-recording audio
    ScreenRecorder.swift          ScreenCaptureKit video + AVAssetWriter muxing
  Helpers/
    AppState.swift                Apps, helper-process attribution, settings → routes
    RecordingLocation.swift       Recording folders (security-scoped bookmarks)
    SelfTest.swift                Debug-only automated checks (compiled out of Release)
  Views/                          Menu bar, mixer window, Settings, shared components
Resources/                        Info.plist, entitlements, privacy manifest, assets
Design/LegacyIcons/               Earlier icon designs (not part of the build)
```

## Debug self-tests

Debug builds accept launch arguments that exercise the real audio paths without
the UI, reporting to stderr and the unified log (`subsystem: com.hassan.Aura`):

```bash
AURA=…/Debug/Aura.app/Contents/MacOS/Aura
afplay tone.wav & "$AURA" -AuraSelfTestRoutePID $! -AuraSelfTestVolume 0.5   # tap + route + levels
"$AURA" -AuraSelfTestScreenSeconds 4                                          # screen recording + analysis
"$AURA" -AuraSelfTestEnvironment YES                                          # sandbox capabilities
"$AURA" -AuraSelfTestIdleSeconds 20                                           # idle CPU
```

None of this code exists in Release builds.
