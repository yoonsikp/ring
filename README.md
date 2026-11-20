# Ring

A minimal macOS menu-bar SIP client (audio only) based on SwiftUI and [liblinphone](https://gitlab.linphone.org/BC/public/linphone-sdk).

- SRTP is **mandatory**: calls that can't use SRTP fail.
- Settings: SIP address, password (Keychain), optional username, optional server, TLS on/off
- Menu-bar icon shows arrows for incoming/outgoing calls · waveform and timer during a call
- In a call: mute, DTMF keypad (click, or type 0-9 * #), hang up
- Phone numbers are formatted using [PhoneNumberKit](https://github.com/marmelroy/PhoneNumberKit), based on your Mac's region or chosen under Account.
- Network: Enable IPv6 (default on), STUN/TURN server, ICE, TURN with username + password (Keychain)
- Audio: echo cancellation, adaptive or fixed-size buffer, volume gain (0 to +6 dB, applied live), and codecs —
  only G.711 (PCMU/PCMA), G.722 and GSM can be enabled
- Connect/disconnect switch in the popover
- Incoming call notification through macOS - Accept/Decline

Requires macOS 13+. See `BUILD.md` or download from releases.
