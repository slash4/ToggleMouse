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
7. Optional: under each receiver, set **Screen edge** to the side of the emitter it sits on.
   Push the cursor through that edge to switch to it, and through the opposite edge on the
   receiver to come back. The cursor crosses at the matching height. Edges where another
   display continues, and drags, never switch.

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
- **Transport**: keys, clicks, scroll and heartbeats use TCP (Nagle off), so nothing is
  lost or reordered. Pointer movement uses UDP on the same port, encrypted with a separate
  session key. Each datagram carries the running total of movement plus a sequence number,
  so a lost datagram costs nothing and stale ones are dropped. The latest total is also sent
  over TCP before each click or scroll, and every 100 ms in case UDP is blocked. Datagrams
  are marked as interactive voice traffic for Wi-Fi priority, and the app opts out of
  App Nap so macOS doesn't throttle it in the background.
- **Smoothing**: Wi-Fi delivers packets in bursts. The receiver uses a jitter buffer
  instead of applying each update on arrival. Each update carries its capture time on the
  emitter. The receiver schedules it at that time, plus the lowest delay seen recently, plus
  a buffer that adapts between 2 and 40 ms. The buffer covers 95% of the measured variation
  and one mouse report interval. A 2 ms timer on a dedicated high-priority thread moves the
  cursor along the interpolated path. Clicks and scrolls flush the buffer first, so they land
  where the cursor is.
- **AirDrop helper**: AWDL (the Wi-Fi peer-to-peer link behind AirDrop, Universal Control,
  Sidecar and AirPlay) hops the radio between channels, which delays packets in bursts. With
  "Turn off AirDrop while streaming" checked, a privileged helper (`ToggleMouseHelper`,
  registered through `SMAppService` and approved in System Settings › General › Login Items)
  keeps `awdl0` down while a stream is active on that Mac. AWDL comes back when streaming
  stops, or when the app quits or crashes, if it was up before. The helper only accepts XPC
  connections from ToggleMouse signed by the same team, can only switch `awdl0`, and exits when
  idle. Unchecking the setting unregisters it.
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
