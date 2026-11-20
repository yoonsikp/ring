# Ring

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

## Releasing

`make release` builds a universal app signed with your **Developer ID**, has Apple notarize it, and
writes `dist/Ring-<version>.zip`. It opens on any Mac without warnings, and because every build
carries the same identity, macOS stops asking for your password to read the saved SIP password.

One-time setup:

1. **Developer ID certificate:** Xcode › Settings › Accounts › your team › *Manage Certificates…*
   › **+** › *Developer ID Application*.
2. **App-specific password:** create one at account.apple.com › Sign-In and Security.
3. **Notary profile** (stored in your keychain):

   ```bash
   xcrun notarytool store-credentials ring-notary --apple-id you@example.com --team-id ABCDE12345 --password <app-specific password>
   ```

Then, for each release (bump `MARKETING_VERSION` in `project.yml` first):

```bash
make release TEAM=ABCDE12345
```

Add `SMALL=1` to use the minimal SDK from `make sdk`. Your Team ID is at developer.apple.com ›
Account › Membership details.

The first time a Developer ID build reads the saved password, macOS may ask once more (the earlier
ad-hoc builds created that Keychain item); choose **Always Allow**, and it won't ask again.

## First-run setup

1. **Allow the microphone and notifications** when Ring asks on first launch.
2. **Set Ring to Alerts:** open *System Settings › Notifications › Ring* and change the alert
   style from **Banners** to **Alerts**. Banners disappear after a few seconds and hide the
   Answer / Decline buttons behind *Options*; Alerts stay on screen until you act.

## Phone links

Ring can open `tel:`, `sip:`, `sips:` and `callto:` links (e.g. "Call" links on web pages). Click
**Use Ring for phone links** under Account › Advanced Options once (macOS asks to confirm). A
clicked link then fills in the number and opens Ring; press Call to dial.

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
