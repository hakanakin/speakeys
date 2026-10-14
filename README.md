# Speakeys

**Whisper to type.** Speakeys is a tiny dictation app for macOS with a floating wireframe orb.

🌐 **Website:** [speakeys.akins.app](https://speakeys.akins.app)

Tap **Right ⌘** and start talking. Your words appear in a small caption bubble while you speak. When you go quiet, Speakeys types them wherever your cursor is. While you are not dictating, the orb rests quietly in a corner of the screen.

- **Works like macOS Dictation:** tap Right Command to start. Speakeys stops by itself after about 2 seconds of silence, or you can tap again to finish early. Press Esc to cancel.
- **Or push-to-talk:** hold Right Command while you speak, and the text is typed when you let go.
- **Choose your own shortcut:** Right ⌘ (the default), Right ⌥, Right ⌃, Right ⇧ or Fn. You can also record any combination, such as ⌃⌥Space or an F-key. When the trigger is a single key, using it with another key (e.g. ⌘C) still works as a normal shortcut.
- **Live captions:** see what's being recognized while you speak.
- **Types anywhere:** the text is pasted at your cursor in any app, and your clipboard is restored afterwards.
- **14 languages:** English, Türkçe, Deutsch, Français, Español, Italiano, Português, Nederlands, Русский, العربية, 日本語, 한국어 and 中文. Only languages your Mac supports are shown.
- **Private:** recognition runs on-device when your Mac supports it. The microphone is only on while you're dictating, and nothing is recorded or saved.
- **Feels like a real Mac app:** Launch at Login, optional start/stop sounds, a menu bar icon that fills while Speakeys is listening, an app icon and an About window.
- **Small and simple:** one Swift file and no dependencies. You don't need an Xcode project to build it.

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

`build.sh` compiles `main.swift`, generates the app icon with `make_icon.swift`, and creates `Speakeys.app` next to it. To build, copy Speakeys to `/Applications` and launch it in one step:

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

Bump `VERSION` in `build.sh` before each release.

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
- change the orb's **Size** and **Position**,
- turn on **Play Sounds** or **Launch at Login**,
- **Hide** (⌘H while the menu is open) or **Quit** Speakeys.

If the Accessibility permission is missing, the menu shows a warning that opens the right page in System Settings.

If you choose **Fn** as the shortcut, set **System Settings → Keyboard → Press 🌐 key to** *Do Nothing*. Otherwise macOS also reacts to the Fn key.

## Troubleshooting

**The orb reacts but no text appears.** Speakeys doesn't have Accessibility permission. When this happens, it puts the text on your clipboard so you can paste it with ⌘V.

To fix it, open **System Settings → Privacy & Security → Accessibility**. Remove Speakeys with **–**, add `Speakeys.app` again with **+**, and restart Speakeys. You may need to do this after rebuilding with an ad-hoc signature.

Speakeys writes problems to `~/Library/Logs/Speakeys.log`.

## How it works

- **Speakeys:** an icosphere drawn with Core Graphics. Its surface is bent by a few layered sine waves, and their speed and strength follow your voice level.
- **Speech:** audio from `AVAudioEngine` goes to `SFSpeechRecognizer`, which streams partial results to the caption bubble.
- **Shortcuts:** a single key like Right ⌘ is detected from modifier-key events. Combinations like ⌃⌥Space are registered as system hot keys, so the key press doesn't also reach the app you're typing in.
- **Typing:** on release, the final text is placed on the clipboard and pasted with a simulated ⌘V. The previous clipboard contents are put back afterwards.

## Website

The landing page is in `site/`. It is a static page deployed as a Cloudflare Worker with static assets:

```sh
cd site && npx wrangler deploy
```

## License

[MIT](LICENSE)
