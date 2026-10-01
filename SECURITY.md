# Security

ToggleMouse captures and injects keyboard input, so security issues matter.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/slash4/ToggleMouse/security/advisories/new)
rather than in a public issue.

## Status of the cryptography

The protocol has **not been independently audited**. It is built only from CryptoKit
primitives, but the way they are combined is custom:

- **Pairing**: numeric comparison with a commitment, modeled on Bluetooth Secure Simple
  Pairing. A man in the middle succeeds with probability 10⁻⁶ per attempt, and each attempt
  requires a user to confirm a code on both Macs while the receiver's 2-minute pairing window
  is open.
- **Sessions**: a Noise-KK-style handshake (X25519 with ee, es and se terms, HKDF-SHA256 over
  the transcript) between pinned static keys and fresh ephemeral keys.
- **Transport**: ChaCha20-Poly1305 with a key per direction and counter nonces over TCP. Pointer
  datagrams over UDP use a separate key, with the sequence number as nonce, and stale or
  replayed datagrams are rejected.

Known limitations:

- Anyone who steals a Mac's private key from its Keychain can impersonate that Mac until
  it is unpaired on the other side. There is no key rotation. Recorded past sessions stay
  protected, because session keys also depend on ephemeral keys.
- No rate limiting on pairing attempts beyond the pairing window.
- Traffic patterns, such as typing rhythm, are visible to anyone on the network.

The root helper (`ToggleMouseHelper`) only accepts XPC connections from the ToggleMouse app
signed by the same team, and can only take the `awdl0` interface up or down.

Reviews of the protocol and the helper are very welcome.
