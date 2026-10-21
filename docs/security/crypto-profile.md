# EnCryNote v1 crypto profile

Status: implemented and exercised on macOS and an Android emulator (Task 1).
Measured on a real low-end Android device: **Not run**, so the v1 Argon2id
profile is not yet approved for release.

## Suite

| Item | v1 value |
| --- | --- |
| KDF | Argon2id (RFC 9106), version 19, `package:cryptography` 2.9.0 pure-Dart implementation |
| Argon2id memory | 19456 KiB (19 MiB) |
| Argon2id iterations | 2 |
| Argon2id parallelism | 1 |
| Argon2id hash length | 32 bytes |
| KDF salt | 16 random bytes per wrapper (separate salt for password and recovery) |
| AEAD | AES-256-GCM, 32-byte key, 12-byte random nonce per encryption, 16-byte tag |
| Data key | 32 random bytes, generated per vault |
| Randomness | `dart:math` `Random.secure()` |

The parser accepts only this profile. Any other `kdf` value, version, or suite
is rejected with `FailureCode.unsupported` before a KDF is run. Parameters are
not negotiated and must not be silently relaxed.

## Limits (shared by reader and writer)

| Limit | Value |
| --- | --- |
| Plaintext payload JSON | 8 MiB |
| Envelope (file) | 16 MiB |
| Imported `.md` (later task) | 1 MiB |

Over-limit writes fail with `FailureCode.limit`; nothing is truncated.

## Envelope format

UTF-8 JSON, keys in the order below, binary fields base64:

```json
{
  "type": "local",
  "version": 1,
  "suite": "argon2id-aes256gcm",
  "vaultId": "<32 hex chars>",
  "kdf": {"algorithm": "argon2id", "memory": 19456, "iterations": 2,
          "parallelism": 1, "hashLength": 32, "salt": "<base64 16B>"},
  "passwordWrap": {"nonce": "...", "ciphertext": "...", "tag": "..."},
  "recovery": {
    "questions": ["...", "...", "..."],
    "kdf": {"algorithm": "argon2id", "memory": 19456, "iterations": 2,
            "parallelism": 1, "hashLength": 32, "salt": "<base64 16B>"},
    "wrap": {"nonce": "...", "ciphertext": "...", "tag": "..."}
  },
  "payload": {"nonce": "...", "ciphertext": "...", "tag": "..."}
}
```

- `type` is `local` for the vault and `export` for export files. Export
  envelopes are a different type and cannot be parsed as local vaults.
- The recovery questions are public header text by design; answers are never
  stored in the clear.
- The plaintext payload is JSON `{"revision": <int>, "autoLock": "...",
  "notes": [...]}`; every note timestamp is UTC ISO-8601 and every note ID is
  16 random bytes in hex.
- Export payloads contain only notes and are never derived from the local
  header (later task).

## AAD

AAD is a canonical JSON array of UTF-8 values, one domain per use:

| Use | AAD array |
| --- | --- |
| Local payload | `["encrynote/local-payload", 1, "argon2id-aes256gcm", vaultIdHex, passwordSaltB64, recoverySaltB64, [q1,q2,q3], pwWrapNonceB64, pwWrapCiphertextB64, pwWrapTagB64, recWrapNonceB64, recWrapCiphertextB64, recWrapTagB64]` |
| Password wrap | `["encrynote/password-wrap", 1, "argon2id-aes256gcm", vaultIdHex]` |
| Recovery wrap | `["encrynote/recovery-wrap", 1, "argon2id-aes256gcm", vaultIdHex, [q1, q2, q3]]` |
| Export payload (later) | `["encrynote/export-payload", 1, "argon2id-aes256gcm", exportIdHex]` |
| Export wrap (later) | `["encrynote/export-wrap", 1, "argon2id-aes256gcm", exportIdHex]` |

Wrappers are deliberately not bound to the payload revision, so autosave and
password rewrap do not need the old password. The recovery AAD binds question
order and text, so edited prompts only become authentic when the recovery wrap
verifies.

The payload AAD additionally authenticates every header field the writer
retains on re-emit: both salts, the recovery question texts, and both wrappers'
nonce/ciphertext/tag. Consequences:

- Any edit to the recovery block (questions, recovery salt, or recovery wrap)
  is detected on the password unlock path, not only on recovery.
- `seal` and `rewrapPassword` decrypt the current payload with the supplied
  data key before emitting. A mismatched envelope/key pair, or a tampered
  retained header, fails with `FailureCode.format` instead of producing an
  unopenable or unrecoverable vault.
- Recovery still works after `rewrapPassword`, because only the password salt
  and password wrap change; the payload is re-sealed under the amended AAD.


## Recovery answer encoding

The three trimmed answers are hashed as a JSON array of strings
(`["Rex","Blue House","SMA 1"]`), never as concatenated text. Edge whitespace is
trimmed; capitalization and inner spaces are preserved. Password values are
neither trimmed nor case-folded, and length is counted in grapheme clusters
(`characters`).

No Unicode normalization is applied to passwords or answers. Input is used
exactly as typed, so the same password typed in NFC and NFD forms derives
different keys; users must enter the same bytes they set. This is deliberate for
v1 (normalizing would silently change user input and complicate cross-platform
equality) and must be revisited before any feature that compares password text
across devices.

## Measured results

Fix round 1 (amended header-authentication code) re-ran the native checks; the
numbers below are from the amended code.

`flutter test integration_test/crypto_platform_test.dart -d macos` on macOS
27.0.1 (arm64, debug build, 2026-10-22):

| Operation | Time |
| --- | --- |
| `createVault` (2 Argon2id derivations + wraps + payload seal) | 198 ms |
| `unlock` (1 Argon2id derivation) | 75 ms |
| `recover` (1 Argon2id derivation) | 72 ms |
| `seal` (AES-GCM only, small payload) | < 1 ms |
| Envelope size for the synthetic fixture | 1138 B |

`flutter test integration_test/crypto_platform_test.dart -d emulator-5554`
(Android 17 / API 37, arm64 emulator, debug build, amended code, two runs):

| Operation | Time |
| --- | --- |
| `createVault` | 7129–8423 ms (includes JIT warm-up) |
| `unlock` | 2340–2479 ms |
| `recover` | 1272–1836 ms |
| `seal` | 128–250 ms |
| Envelope size | 1138 B |

The amended integration test also proves on-device: seal → reseal round-trip,
`rewrapPassword` keeping notes, recovery still working after a password rewrap,
and rejection (`FailureCode.format`) of tampered recovery questions.

Round-trip, recovery-key equality, reseal and wrong-password rejection passed on
both platforms.

These numbers are single debug-build measurements on one machine, not a
performance guarantee. Android debug builds run without AOT and the emulator is
not a low-end device, so the unlock figure is an upper-ish bound only.
Run the same integration test on a real low-end Android device before treating
this profile as release-ready; if it is too slow there, change the profile
explicitly (new documented v1 parameters) rather than silently.
