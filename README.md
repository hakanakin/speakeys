# Speakeys

**Whisper to type.** Speakeys is a tiny dictation app for macOS with a floating wireframe orb.

🌐 **Website:** [speakeys.akins.app](https://speakeys.akins.app)

Tap **Right ⌘** and start talking. Your words appear in a small caption bubble while you speak. When you go quiet, Speakeys types them wherever your cursor is. While you are not dictating, the orb rests quietly in a corner of the screen.

- **Works like macOS Dictation:** tap Right Command to start. Speakeys stops by itself after about 2 seconds of silence, or you can tap again to finish early. Press Esc to cancel.
- **Or push-to-talk:** hold Right Command while you speak, and the text is typed when you let go.
- **Choose your own shortcut:** Right ⌘ (the default), Right ⌥, Right ⌃, Right ⇧ or Fn. You can also record any combination, such as ⌃⌥Space or an F-key. When the trigger is a single key, using it with another key (e.g. ⌘C) still works as a normal shortcut.
- **Make it yours:** choose the orb's color (seven presets or any custom color) and its motion (Calm, Balanced or Lively).
- **Update alerts:** Speakeys checks once a day for a new version and sends a notification when one is out. You can turn this off.
- **Live captions:** see what's being recognized while you speak.
- **Types anywhere:** the text is pasted at your cursor in any app, and your clipboard is restored afterwards.
- **14 languages:** English, Türkçe, Deutsch, Français, Español, Italiano, Português, Nederlands, Русский, العربية, 日本語, 한국어 and 中文. Only languages your Mac supports are shown.
- **Private:** recognition runs on-device when your Mac supports it. The microphone is only on while you're dictating, and nothing is recorded or saved. The only network request is the daily update check, which you can turn off.
- **Feels like a real Mac app:** Launch at Login, optional start/stop sounds, a menu bar icon that fills while Speakeys is listening, an app icon and an About window.
- **Light on your Mac:** about 0.3% CPU at rest. The orb is drawn on the GPU and pauses while hidden or while the display sleeps.
- **Small and simple:** a few small Swift files and no dependencies. You don't need an Xcode project to build it.

## Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```sh
git clone https://github.com/hakanakin/speakeys.git
cd speakeys
./build.sh
open Speakeys.app
```

`build.sh` compiles everything in `Sources/`, draws the app icon with `Tools/make-icon`, and creates `Speakeys.app` next to it. To build, copy Speakeys to `/Applications` and launch it in one step:

```sh
./build.sh --install
```

Install Speakeys in `/Applications` before you turn on **Launch at Login**. To use your own bundle identifier:

```sh
BUNDLE_ID=com.yourname.speakeys ./build.sh
```

If you have an Apple Development certificate, the script signs the app with it. Otherwise it uses an ad-hoc signature. With an ad-hoc signature, macOS may forget the Accessibility permission each time you rebuild (see Troubleshooting).

## Releasing

`release.sh` builds a signed and notarized `dist/Speakeys-<version>.dmg` that opens without Gatekeeper warnings. It needs an Apple Developer Program membership. Setup steps are at the top of the script.

```sh
./release.sh            # build the DMG
./release.sh --publish  # build it and attach it to a new GitHub release
```

Bump `VERSION` in `build.sh` before each release. `release.sh` also copies the DMG and a `version.json` (read by the app's update check) into a local `site/public/` folder for the website, if one exists. The website itself isn't part of this repository.

## Permissions

On first launch, macOS asks for three permissions:

| Permission | Why |
| --- | --- |
| Microphone | To hear you while you're dictating |
| Speech Recognition | To turn your speech into text |
| Accessibility | To notice the Right ⌘ key and paste the text into other apps |

You can grant Accessibility in **System Settings → Privacy & Security → Accessibility**. Quit and reopen Speakeys after granting it.

## Usage

Click into any text field and then:

- **Tap Right ⌘** and speak. Speakeys types the text after about 2 seconds of silence. Tap again to finish early, or press **Esc** to cancel.
- Or **hold Right ⌘** while you speak, and release to type.

Use the menu bar icon to:

- choose a **Shortcut**, or pick **Record Shortcut…** and press any combination,
- choose the **Language**,
- pick the orb's **Motion** and **Color**,
- change the orb's **Size** and **Position**,
- turn on **Play Sounds**, **Launch at Login** or **Check for Updates Automatically**, or **Check for Updates…** now,
- **Hide** (⌘H while the menu is open) or **Quit** Speakeys.

If the Accessibility permission is missing, the menu shows a warning that opens the right page in System Settings.

If you choose **Fn** as the shortcut, set **System Settings → Keyboard → Press 🌐 key to** *Do Nothing*. Otherwise macOS also reacts to the Fn key.

## Troubleshooting

**The orb reacts but no text appears.** Speakeys doesn't have Accessibility permission. When this happens, it puts the text on your clipboard so you can paste it with ⌘V.

To fix it, open **System Settings → Privacy & Security → Accessibility**. Remove Speakeys with **–**, add `Speakeys.app` again with **+**, and restart Speakeys. You may need to do this after rebuilding with an ad-hoc signature.

Speakeys writes problems to `~/Library/Logs/Speakeys.log`.

## How it works

- **Orb:** an icosphere whose surface is bent by a few layered sine waves. Their speed and strength follow your voice level. Each frame only projects about 640 points. The edges are stroked by `CAShapeLayer`s, so rasterizing and the glow happen on the GPU. The orb runs at 30 fps at rest and 60 fps while dictating, and stops drawing when it's covered or the display sleeps.
- **Speech:** audio from `AVAudioEngine` goes to `SFSpeechRecognizer`, which streams partial results to the caption bubble.
- **Shortcuts:** a single key like Right ⌘ is detected from modifier-key events. Combinations like ⌃⌥Space are registered as system hot keys, so the key press doesn't also reach the app you're typing in.
- **Typing:** on release, the final text is placed on the clipboard and pasted with a simulated ⌘V. The previous clipboard contents are put back afterwards.

## Project layout

| File | What it does |
| --- | --- |
| `Sources/AppDelegate.swift` | Connects the shortcut, dictation, orb, caption and text insertion |
| `Sources/ShortcutMonitor.swift` | Watches the trigger system-wide and tells a tap from a hold |
| `Sources/Shortcut.swift` | The `Trigger` model, presets and key names |
| `Sources/ShortcutRecorder.swift` | The "Record Shortcut…" window |
| `Sources/Dictation.swift` | One speech recognition session: partial text, silence detection, final text |
| `Sources/Microphone.swift` | Audio capture while dictating, and the loudness level |
| `Sources/TextInserter.swift` | Pastes the text and restores the full clipboard afterwards |
| `Sources/OrbView.swift` | The animated orb |
| `Sources/Icosphere.swift` | Orb geometry, shared with the icon tool |
| `Sources/CaptionPanel.swift` | The live transcript bubble |
| `Sources/MenuBarController.swift` | The menu bar icon and menu |
| `Sources/Settings.swift` | Preferences, plus the language, size, position, motion and color options |
| `Sources/UpdateChecker.swift` | Daily check of `version.json` on the website, and the update notification |
| `Sources/Overlay.swift`, `Log.swift`, `main.swift` | Small helpers and the entry point |
| `Tools/make-icon/` | Draws `AppIcon.icns` at build time |

## License

[MIT](LICENSE)
