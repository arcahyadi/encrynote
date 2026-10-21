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
| Local payload | `["encrynote/local-payload", 1, "argon2id-aes256gcm", vaultIdHex]` |
| Password wrap | `["encrynote/password-wrap", 1, "argon2id-aes256gcm", vaultIdHex]` |
| Recovery wrap | `["encrynote/recovery-wrap", 1, "argon2id-aes256gcm", vaultIdHex, [q1, q2, q3]]` |
| Export payload (later) | `["encrynote/export-payload", 1, "argon2id-aes256gcm", exportIdHex]` |
| Export wrap (later) | `["encrynote/export-wrap", 1, "argon2id-aes256gcm", exportIdHex]` |

Wrappers are deliberately not bound to the payload revision, so autosave and
password rewrap do not need the old password. The recovery AAD binds question
order and text, so edited prompts only become authentic when the recovery wrap
verifies.

## Recovery answer encoding

The three trimmed answers are hashed as a JSON array of strings
(`["Rex","Blue House","SMA 1"]`), never as concatenated text. Edge whitespace is
trimmed; capitalization and inner spaces are preserved. Password values are
neither trimmed nor case-folded, and length is counted in grapheme clusters
(`characters`).

## Measured results

`flutter test integration_test/crypto_platform_test.dart -d macos` on macOS
27.0.1 (arm64, debug build, 2026-10-22):

| Operation | Time |
| --- | --- |
| `createVault` (2 Argon2id derivations + wraps + payload seal) | 193 ms |
| `unlock` (1 Argon2id derivation) | 74 ms |
| `recover` (1 Argon2id derivation) | 65 ms |
| `seal` (AES-GCM only, small payload) | < 1 ms |
| Envelope size for the synthetic fixture | 1138 B |

`flutter test integration_test/crypto_platform_test.dart -d emulator-5554`
(Android 17 / API 37, arm64 emulator, debug build, first run after cold start):

| Operation | Time |
| --- | --- |
| `createVault` | 3815–9288 ms (two runs; includes JIT warm-up) |
| `unlock` | 637–876 ms |
| `recover` | 775–860 ms |
| `seal` | 45–49 ms |
| Envelope size | 1138 B |

Round-trip, recovery-key equality, reseal and wrong-password rejection passed on
both platforms.

These numbers are single debug-build measurements on one machine, not a
performance guarantee. Android debug builds run without AOT and the emulator is
not a low-end device, so the ~0.8 s unlock figure is an upper-ish bound only.
Run the same integration test on a real low-end Android device before treating
this profile as release-ready; if it is too slow there, change the profile
explicitly (new documented v1 parameters) rather than silently.
