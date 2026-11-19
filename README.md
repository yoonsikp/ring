# Ring

A minimal macOS menu-bar SIP client (audio only). It's a small SwiftUI app on top of
[liblinphone](https://gitlab.linphone.org/BC/public/linphone-sdk) (the engine behind Linphone),
which handles SIP, TLS, SRTP and audio.

- Menu-bar icon shows the state: `phone.fill` connected · `phone` connecting · `phone.down` disconnected/failed
  · arrows for incoming/outgoing calls · waveform during a call
- One account, one call at a time (`maxCalls = 1`; a second incoming call gets *486 Busy*)
- Settings: SIP address, username, password (stored in the Keychain), optional server, TLS on/off
- SRTP is **mandatory**: calls that can't use SRTP fail
- In a call: mute, DTMF keypad (click, or type 0-9 * #), hang up
- Connect/disconnect switch in the popover
- Settings: echo cancellation, play tones for keys the caller presses (off by default), and codecs —
  only PCMU, PCMA, G.722 and GSM can be enabled; every other codec is disabled (telephone-event stays on for DTMF); optional comfort noise (CN, RFC 3389)

Requires macOS 13+.

## Build

You need Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run        # generates Ring.xcodeproj, builds Release, launches the app
```

Or run `make project` and open `Ring.xcodeproj` in Xcode. Swift Package Manager downloads the
linphone SDK (`linphonesw`, pinned to 5.5.41) on the first build.

The app is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`). macOS asks for microphone access the first
time you place or answer a call.

## Layout

| File | Role |
|---|---|
| `Ring/RingApp.swift` | `MenuBarExtra` scene, menu-bar icon, app delegate |
| `Ring/SIPManager.swift` | Wraps the liblinphone `Core`: account, registration, calls, mute, DTMF |
| `Ring/MenuView.swift` | Popover UI: status, dialer, call controls, keypad, account and settings pages |
| `Ring/AccountSettings.swift` | Account settings in UserDefaults, password in Keychain |
| `Ring/AudioSettings.swift` | Echo cancellation, DTMF tones, codec selection |
| `project.yml` | XcodeGen spec (Info.plist and entitlements are generated from it) |

## Known gaps / to check on first run

- **Incoming calls:** only the icon changes and liblinphone plays its ring tone. The popover doesn't
  open by itself, and there are no notifications yet.
- **TLS certificates:** the server certificate is verified (liblinphone's default). A PBX with a
  self-signed certificate will fail to register over TLS.
- No audio device picker: the system default input and output are used.

## License

AGPL-3.0 (see `LICENSE`). liblinphone is GPL-3.0, which is compatible.
