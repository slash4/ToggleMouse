# ToggleMouse

Share one Mac's mouse and keyboard with other Macs on the same network. The same app runs
in two modes:

- **Emitter**: the Mac the mouse and keyboard are plugged into. A per-receiver shortcut
  toggles streaming to that receiver.
- **Receiver**: replays the streamed input as if it were local.

The menu bar icon is grey when idle, red while emitting and green while receiving.

## Build

```sh
./scripts/build-app.sh          # builds and signs build/ToggleMouse.app
swift test                      # protocol and crypto tests
```

Signing uses `$SIGN_IDENTITY` if set, otherwise the first Developer ID Application identity,
otherwise the first Apple Development identity. Use a stable identity: macOS ties the
Accessibility permission and the Keychain item to the signature, so ad-hoc builds ask again
after every rebuild.

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

## Setup

1. Copy `ToggleMouse.app` to both Macs and open it.
2. Grant **Accessibility** (System Settings › Privacy & Security) on both Macs, and allow
   **Local Network** access when asked.
3. On the receiver, choose **Receiver** and click **Allow Pairing for 2 Minutes**.
4. On the emitter, choose **Emitter** and click **Pair…** next to the receiver, or enter its IP.
5. Both Macs show a 6-digit code. If the codes match, click **Codes Match** on each Mac.
6. Press the receiver's shortcut (default ⌃⌥⌘1, ⌃⌥⌘2, …) to stream to it. Press it again to
   take control back. Click the shortcut button in the window to change it.

## How it works

- **Discovery**: receivers advertise `_togglemouse._tcp` over Bonjour on TCP port 52525. Each
  paired receiver can also use a fixed address, which overrides Bonjour.
- **Pairing**: each Mac has a Curve25519 key pair in its login Keychain. Pairing works like
  Bluetooth numeric comparison. The emitter commits to its key before it sees the receiver's
  key, then both Macs show a code derived from both keys and both nonces. A man in the middle
  gets the same code on both sides only 1 time in 10⁶, and each attempt needs a user to
  confirm it. The paired public keys are stored in
  `~/Library/Application Support/ToggleMouse/peers.json`.
- **Sessions**: a Noise-KK-style handshake combines the two pinned static keys with fresh
  ephemeral keys. Traffic uses ChaCha20-Poly1305 with a separate key for each direction and
  counter nonces, so replayed or altered frames are rejected. A Mac without the paired private
  key can't complete the handshake.
- **Capture**: an active `CGEventTap` on the emitter swallows input while streaming and freezes
  the local cursor with `CGAssociateMouseAndMouseCursorPosition`. Keys are sent as raw key codes.
- **Failsafe**: the emitter sends a heartbeat every 2 s. If the link drops or goes silent for 6 s,
  the emitter takes control back. When a stream ends or drops, the receiver releases every key,
  button and modifier that is still held.

## Limitations (v1)

- Movement, buttons, scroll and keys only. No gestures, media keys, clipboard or login window.
- While Secure Input is on (for example, a focused password field on the emitter), macOS hides
  keystrokes from the event tap.
- The emitter's cursor stays visible, frozen in place, while streaming.
