# Ring

A minimal macOS menu-bar SIP client (audio only). It's a small SwiftUI app on top of
[liblinphone](https://gitlab.linphone.org/BC/public/linphone-sdk) (the engine behind Linphone),
which handles SIP, TLS, SRTP and audio.

- SRTP is **mandatory**: calls that can't use SRTP fail.
- Settings: SIP address, password (stored in the Keychain)
- Optional username, optional server, TLS on/off
- Menu-bar icon shows arrows for incoming/outgoing calls · waveform and timer during a call
- Phone numbers are formatted for your country as you type and for callers,
  using [PhoneNumberKit](https://github.com/marmelroy/PhoneNumberKit). The country is
  automatic (your Mac's region) or chosen under Account.
- In a call: mute, DTMF keypad (click, or type 0-9 * #), hang up
- Connect/disconnect switch in the popover
- Network: Enable IPv6 (default on), STUN/TURN server, ICE, TURN with username + password (Keychain)
- Audio: echo cancellation, adaptive or fixed-size jitter buffer, volume gain (0 to +6 dB, applied live), and codecs —
  only G.711 (PCMU/PCMA), G.722 and GSM can be enabled; every other codec is disabled

Requires macOS 13+.
