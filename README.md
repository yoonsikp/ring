# Ring

A minimal macOS menu-bar SIP client (audio only). It's a small SwiftUI app on top of
[liblinphone](https://gitlab.linphone.org/BC/public/linphone-sdk) (the engine behind Linphone),
which handles SIP, TLS, SRTP and audio.

- Menu-bar icon shows the state: `phone.fill` connected · `phone` connecting · `phone.down` disconnected/failed
  · arrows for incoming/outgoing calls · waveform during a call
- One account, one call at a time (`maxCalls = 1`; a second incoming call gets *486 Busy*)
- Settings: SIP address, username, password (stored in the Keychain), optional server, TLS on/off
- Phone numbers are formatted for your country (brackets, spaces, hyphens) as you type and for
  callers, using [PhoneNumberKit](https://github.com/marmelroy/PhoneNumberKit). The country is
  automatic (your Mac's region) or chosen under Account; formatting is stripped before dialling.
- SRTP is **mandatory**: calls that can't use SRTP fail
- In a call: mute, DTMF keypad (click, or type 0-9 * #), hang up
- Connect/disconnect switch in the popover
- Network: Enable IPv6 (default on), STUN/TURN server, ICE, TURN with username + password (Keychain)
- Audio: echo cancellation, adaptive or fixed-size jitter buffer, volume gain (0 to +6 dB, applied live), and codecs —
  only G.711 (PCMU/PCMA), G.722 and GSM can be enabled; every other codec is disabled (telephone-event stays on for DTMF)

Requires macOS 13+.

## Build

You need Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run        # generates Ring.xcodeproj, builds Release, launches the app
```

Builds are **universal** (Intel and Apple Silicon). `make native` builds for this Mac's processor
only, about half the size. `make size` shows what takes the space.

Or run `make project` and open `Ring.xcodeproj` in Xcode. Swift Package Manager downloads the
linphone SDK (`linphonesw`, pinned to 5.5.41) and PhoneNumberKit (4.3.0) on the first build.

### Smallest build (minimal SDK from source)

The prebuilt linphone SDK includes video, a noise-suppression neural network, group chat and
more, which Ring doesn't use. To build a minimal SDK (audio only, universal; `make sdk-native`
for this Mac's processor only):

```bash
brew install cmake ninja doxygen yasm nasm
/usr/bin/python3 -m pip install --user pystache six
make sdk      # once; slow (clones and builds the SDK into build/)
make small    # build and run Ring against it
make size
```

### Logging

Logging is off normally (logs contain the call's SRTP keys). To write detailed liblinphone logs to
`~/Library/Logs/Ring`, launch with `--logging`; a **Logs** button then appears in the popover:

```bash
make run-logging
```

or, for an installed copy: `open -a Ring --args --logging`.

The app is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`). macOS asks for microphone access the first
time you place or answer a call.

## First-run setup

1. **Allow notifications** when Ring asks on first launch.
2. **Set Ring to Alerts:** open *System Settings › Notifications › Ring* and change the alert
   style from **Banners** to **Alerts**. Banners disappear after a few seconds and hide the
   Answer / Decline buttons behind *Options*; Alerts stay on screen until you act.

## Incoming calls

- A notification **Incoming call** appears with the caller, and **Answer** / **Decline** buttons;
  clicking the notification itself also answers.
- If the popover is closed, the menu bar icon turns into a **green answer button**; clicking it
  answers the call and opens the popover on the call controls.
- The caller's number is put in the number field, ready to call back, whether you answer, decline
  or miss the call.
- Focus / Do Not Disturb hides the notification (the green icon still shows).

## Layout

| File | Role |
|---|---|
| `Ring/RingApp.swift` | `MenuBarExtra` scene, menu-bar icon (incl. answer button, call timer), app delegate |
| `Ring/CallNotifier.swift` | Incoming-call notification with Answer / Decline |
| `Ring/CallClock.swift` | Per-second call timer for the menu bar |
| `Ring/SIPManager.swift` | Wraps the liblinphone `Core`: account, registration, calls, mute, DTMF |
| `Ring/MenuView.swift` | Popover UI: status, dialer, call controls, keypad, account and settings pages |
| `Ring/AccountSettings.swift` | Account settings in UserDefaults, password in Keychain |
| `Ring/AudioSettings.swift` | Echo cancellation, jitter buffer, volume gain, codec selection |
| `Ring/NetworkSettings.swift` | IPv6, STUN/TURN server, ICE, TURN credentials |
| `Ring/Theme.swift` | Light/dark adaptive colours |
| `Ring/Sounds/ringtone.mkv` | Ring tone (Opus, mono 48 kHz, at half volume) |
| `Ring/PhoneFormat.swift` | Country-aware phone number formatting (PhoneNumberKit) |
| `Ring/Assets.xcassets` | App icon (source: `design/AppIcon-1024.png`; earlier vector draft in `design/AppIcon.svg`) |
| `project.yml` | XcodeGen spec (Info.plist and entitlements are generated from it) |

## Known gaps / to check on first run

- **TLS certificates:** the server certificate is verified (liblinphone's default). A PBX with a
  self-signed certificate will fail to register over TLS.
- No audio device picker: the system default input and output are used.

## License

AGPL-3.0 (see `LICENSE`). liblinphone is GPL-3.0, which is compatible.
