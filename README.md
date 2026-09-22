# Aura

A native macOS per-app audio mixer and screen recorder.

Aura gives every running app its own volume, mute, stereo balance, and output
device — the per-app audio control macOS doesn't offer on its own — and it can
record the screen **with system audio**, which a normal QuickTime recording
can't capture.

> Requires macOS 14.4+ (built against the macOS 26 SDK, Swift 6). Menu-bar app
> with an optional main window.

## Features

- **Per-app mixer** — adjust volume, mute, and stereo balance for each running
  app independently, from a menu-bar dropdown or a full window.
- **Per-app output routing** — send one app to your speakers and another to
  headphones at the same time.
- **True capture, no double audio** — uses the Core Audio *process-tap* API to
  tap an app's audio while muting its original output, so you don't hear it
  twice. Falls back to ScreenCaptureKit automatically if a tap can't be set up.
- **Screen recording with audio** — one click records the screen and all system
  audio into a single `.mov` (H.264 + AAC). A toggle turns the audio on/off.
- **Spatial soundstage** (secondary) — drag apps around a 2D radar to set their
  volume and balance by position.
- **Per-app recording** (secondary) — capture a single app's audio to a `.wav`.

## Where files are saved

| What | Location |
|------|----------|
| Screen recordings | `~/Movies/Aura Screen Recordings/` (default — change it with the folder button next to the record control) |
| Per-app audio recordings | `~/Music/Aura Recordings/` |

The screen-recording destination is remembered across launches.

## Permissions

Aura needs one or both of these, depending on what you use. It surfaces an
in-app banner with a **Grant** button when access is missing.

- **Audio Recording** (Microphone) — required by the process-tap path to capture
  and control app audio. Grant it when prompted, or in
  *System Settings → Privacy & Security → Microphone*.
- **Screen Recording** — required for the screen recorder, and for the
  ScreenCaptureKit fallback capture path. Grant it in
  *System Settings → Privacy & Security → Screen Recording*.

Nothing is written to disk unless you press Record.

## Building

Aura uses [XcodeGen](https://github.com/yonghyun/XcodeGen); `project.yml` is the
source of truth and `AudioMixer.xcodeproj` is generated from it.

```bash
brew install xcodegen        # once
xcodegen generate            # regenerate the Xcode project
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer -configuration Debug build
```

Or open `AudioMixer.xcodeproj` in Xcode and run. The built product is named
**Aura.app** (bundle id `com.hassan.Aura`).

### Stable local signing (so permissions stick)

By default the app is signed **ad-hoc**, which works but re-signs on every build —
so macOS treats each rebuild as a new app and you have to re-grant Screen
Recording and Microphone every time.

To sign with a stable self-signed identity instead (grant permissions once, and
they persist across rebuilds), run the one-time setup:

```bash
./scripts/setup-local-signing.sh   # creates the "Aura Local Signing" identity
xcodegen generate                  # (only needed if project.yml changed)
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer -configuration Debug build
```

The script creates a self-signed code-signing certificate in your login keychain
and writes `Local.xcconfig` (git-ignored) pointing the build at it. After that,
grant Screen Recording + Microphone to Aura **once** in
*System Settings → Privacy & Security* — the grants survive future rebuilds
because the code signature (and its designated requirement) stays constant.

If you have an Apple Developer account, you can instead set `DEVELOPMENT_TEAM`
and use automatic signing; that's equally stable.

## Project layout

```
Sources/
  AudioMixerApp.swift            App entry point, menu-bar status item + dropdown window
  Helpers/AppState.swift         Observable app/device state, capture lifecycle, permissions
  Audio/
    AudioDeviceManager.swift     CoreAudio (HAL) output-device queries and default routing
    AudioCaptureEngine.swift     Playback engine; prefers process taps, falls back to SCK
    ProcessTapCapture.swift      Core Audio process tap (taps + mutes one app's audio)
    ScreenRecorder.swift         ScreenCaptureKit → AVAssetWriter screen + audio recorder
  Views/
    MenuBarDropdownView.swift    Primary compact mixer surface
    MainWindowView.swift         Full window: mixer grid, spatial tab, inspector
    SharedComponents.swift       Shared slider, level meter, device icons, record control, banner
Resources/                       Info.plist, entitlements, app icons
```

## How the audio path works

1. When you first touch an app's controls, Aura starts a capture stream for it
   (lazily — nothing is tapped until you interact).
2. It prefers a **Core Audio process tap** (`CATapDescription` +
   `AudioHardwareCreateProcessTap` in a private aggregate device). The tap
   captures the app's audio and mutes its normal output.
3. Captured PCM is played back through an `AVAudioEngine` bound to the app's
   chosen output device, applying your volume / mute / pan in the render callback.
4. If a tap can't be created, it falls back to ScreenCaptureKit audio capture
   (which captures but does not mute the original — so you may hear it twice
   until a virtual device like BlackHole is used).
