# Shipping Aura to the Mac App Store

## What's already done in the project

- [x] **App Sandbox** on, with a minimal entitlement set: user-selected files,
      app-scoped bookmarks, Movies and Music folders. No microphone, no network,
      no temporary exceptions.
- [x] Verified **inside the sandbox**: per-app taps, private aggregate devices,
      helper-process attribution, changing the default output, screen recording,
      and writing to ~/Movies / ~/Music.
- [x] **Hardened runtime**, and no `get-task-allow` in Release/archives.
- [x] **Privacy manifest** (`PrivacyInfo.xcprivacy`): no tracking, no collected
      data, UserDefaults reason `CA92.1`.
- [x] Info.plist: `NSAudioCaptureUsageDescription`, `LSApplicationCategoryType`
      (Utilities), `ITSAppUsesNonExemptEncryption = NO`, copyright, versions from
      `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
- [x] Complete app icon (16–1024 px) in the asset catalog.
- [x] Universal binary; `xcodebuild archive` succeeds with zero warnings.
- [x] Debug-only test code is compiled out of Release.
- [x] Permission prompts only appear when a feature is first used.

## What only you can do

### 1. Join the Apple Developer Program
$99/year at <https://developer.apple.com/programs/>. Required to sign for and
submit to the App Store.

### 2. Point the build at your team
Copy `Local.xcconfig.example` to `Local.xcconfig` and use **Option B**:

```
AURA_CODE_SIGN_STYLE = Automatic
AURA_CODE_SIGN_IDENTITY = Apple Development
AURA_DEVELOPMENT_TEAM = <your Team ID>     // Membership page on developer.apple.com
```

Then `xcodegen generate`. Xcode will register the bundle ID `com.hassan.Aura`
and create certificates automatically. (Change the bundle ID in `project.yml`
first if you want a different one — it can't change after release.)

### 3. Create the app in App Store Connect
<https://appstoreconnect.apple.com> → Apps → **+** → New App → macOS, bundle ID
`com.hassan.Aura`. "Aura" alone is almost certainly taken on the store, so pick a
distinctive store name (suggestions below). The name under the icon in Finder
stays "Aura".

### 4. Archive and upload
In Xcode: select **Any Mac**, then **Product → Archive** → **Distribute App** →
**App Store Connect** → Upload. Bump `CURRENT_PROJECT_VERSION` in `project.yml`
for every upload.

### 5. TestFlight, then submit
Install through TestFlight on a clean Mac (or a new macOS user account), run the
checklist below, then submit for review with the notes below.

## Test checklist before submitting

Run these on the **TestFlight build**. Several can only be judged by ear.

- [ ] Fresh install: the first adjustment of an app shows the System Audio
      Recording prompt with Aura's explanation.
- [ ] **Listening test:** play music in Safari/Chrome/Spotify, drag its volume
      in Aura to 25% → it gets quieter (and 100% sounds like before). You should
      never hear two copies or echo.
- [ ] Mute/unmute, balance fully left/right, and "Reset to Normal Audio" restore
      normal playback.
- [ ] Route an app to headphones while another plays on speakers.
- [ ] Unplug the headphones mid-playback: the app falls back to the default
      output instead of going silent.
- [ ] Screen recording with audio while one app is adjusted to 50%: the
      recording sounds like what you heard (no doubling, no hollow/phasey sound).
- [ ] Screen recording with the audio toggle off has no sound track.
- [ ] Choose a custom recordings folder, quit, relaunch, record: it still saves
      there.
- [ ] Quit Aura while recording: the file is still saved.
- [ ] "Open Aura at login" works after a restart and doesn't open the mixer window.
- [ ] VoiceOver can reach and adjust every app's volume.

## App Store Connect metadata (drafts)

**Name** (≤30): `Aura – Per-App Volume Mixer` · alternatives: `Aura Audio Mixer`,
`Aura: App Volume & Recorder`

**Subtitle** (≤30): `Volume for every app`

**Category:** Utilities (secondary: Music)

**Promotional text** (≤170):
> Turn down one app without touching the rest, send your music to headphones
> and your call to speakers, and record your screen with the sound you hear.

**Description:**
> Aura gives every app on your Mac its own volume.
>
> PER-APP VOLUME
> Turn a noisy browser tab down, mute a chat app, or boost your music relative to
> everything else — each app gets its own slider, mute and balance, right from the
> menu bar. Works with browsers, Electron apps, video players and games.
>
> SEND APPS TO DIFFERENT OUTPUTS
> Play music on your speakers while a video call goes to your headphones. Apps
> set to "System Default" follow your Mac when you connect or disconnect devices.
>
> SCREEN RECORDING WITH SOUND
> The built-in screen recorder can't capture what your Mac plays. Aura records the
> screen together with exactly what you hear, in one click, to a standard movie
> file.
>
> RECORD AN APP'S AUDIO
> Save just one app's audio as a WAV file.
>
> PRIVATE BY DESIGN
> All audio stays on your Mac. Aura collects no data and has no network access.
>
> Aura only processes the apps you adjust; everything else plays exactly as
> before. Requires permission for System Audio Recording (and Screen Recording
> for screen recordings).

**Keywords** (≤100):
`volume,mixer,per app,audio,sound,menu bar,output,headphones,screen recorder,record,system audio`

**Support URL / Marketing URL:** required. The GitHub repo page works; a simple
landing page is better.

**Privacy Policy URL:** required. Something like:
> Aura does not collect, store, or transmit any personal data. Audio and screen
> content are processed locally on your Mac and saved only to folders you choose.
> Aura has no network access and contains no analytics or advertising.

**App Privacy (nutrition label):** *Data Not Collected*.

**Export compliance:** handled by `ITSAppUsesNonExemptEncryption = NO`.

**Screenshots:** at least one Mac screenshot at 16:10 (e.g. 2880×1800). Good
subjects: the menu-bar mixer over a desktop, the mixer window with a few apps
playing, the Settings window.

## Notes for App Review

Paste into *App Review Information → Notes*:

> Aura is a per-app volume mixer and screen recorder.
>
> • Per-app volume uses the public Core Audio process-tap API
> (AudioHardwareCreateProcessTap, macOS 14.2+). The first time you move an app's
> volume slider, macOS asks for System Audio Recording permission; Aura uses it
> only to change the volume/output of apps the user adjusts. Apps the user hasn't
> touched are not captured.
> • Screen recording uses ScreenCaptureKit and starts only when the user presses
> "Record Screen". Files are saved to ~/Movies/Aura Screen Recordings or a folder
> the user picks.
> • No data leaves the device; the app has no network entitlement.
>
> To test: play audio in Music or Safari, click the Aura menu-bar icon, drag that
> app's volume slider and allow the permission prompt. Press "Record Screen" to
> test recording.

## Reach: supporting macOS 15

The project targets **macOS 26**, which is what has been tested. It also compiles
unchanged for **macOS 15 (Sequoia)**: change `deploymentTarget` in `project.yml`
to `"15.0"` once you can run the checklist above on a macOS 15 Mac. macOS 14.4 is
possible too, but needs a small change (the mixer-window launch behavior API is
15+).
