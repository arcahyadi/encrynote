# EnCryNote v1 crypto profile

Status: implemented and exercised on macOS and an Android emulator (Task 1).
Measured on a real low-end Android device: **Not run**, so the v1 Argon2id
profile is not yet approved for release.

## Pre-release compatibility (read before persisting a vault)

This is an unpublished, pre-release format. The v1 local layout changed after
commit `c442602` (fix `75570f0` widened the payload AAD); envelopes written by
`c442602` are **not** readable by current code and current envelopes are not
readable by `c442602`.

- There are no user vaults and no migration path. Any test vault, fixture
  envelope, or developer device copy captured at or before `c442602` must be
  **recreated**, not migrated.
- Public compatibility across builds is not promised before the first release.
  Later tasks must not assume that an envelope written by an earlier build can
  be opened by a later one.
- `version` stays `1` by project decision (no user data exists to protect), so
  an old envelope fails as `FailureCode.format` on authentication. Treat that
  as "incompatible pre-release build" for any envelope known to predate
  `75570f0`, not as evidence that the vault is corrupt. Do not delete or
  overwrite a vault on that basis without user confirmation.
- From the first public release onward, any change to the envelope layout or
  AAD must bump `version` so old files fail as `FailureCode.unsupported`.

## Where crypto work runs

`createVault`, `unlock`, `recover`, `seal`, and `rewrapPassword` each perform
their whole job in one helper isolate (`Isolate.run`): envelope JSON/base64,
Argon2id, AES-GCM, and payload serialization all happen off the UI isolate.
Only byte lists, strings, `VaultData`, the parsed header, and a small result
record cross the isolate boundary; the cipher, RNG, and key objects are created
inside it. `readRecoveryQuestions` stays synchronous because it runs no KDF and
only needs the public header, although the current parser still decodes the
whole envelope (see the limit below).

Consequence: these calls are async and their wall-clock cost is unchanged or
slightly higher (one isolate spawn per call, ~67 ms on the Android emulator),
but the UI isolate is not blocked while they run.

The regression check measures the **seal window only**: a 1 ms sampler starts
immediately before `seal` and stops when that single await returns, with no
unlock KDF and no trailing delay inside the window. It asserts progress — at
least one tick lands while the seal is still pending — and records the elapsed
time and worst gap as diagnostics. A seal that ran on the main isolate cannot
tick inside that window, so bypassing the isolate fails the check. There is no
millisecond bound: the check promises that the seal yields, not a maximum stall.
The KDF cost of `unlock`/`recover` is a separate operation and is not inside
this window. Observed values are single-run debug-build diagnostics, not a
performance guarantee.

Known limit: `readRecoveryQuestions` is synchronous by contract and runs no KDF,
but the current parser decodes the **whole** envelope, including base64-decoding
the sealed payload ciphertext into memory, before returning the three question
strings. On a ~9.6 MB envelope that measured 22 ms of wall time and a 23 ms
caller-isolate stall on macOS. It is called before unlock on a screen with no
frame-critical work, so this is accepted for v1 rather than making the API
async or adding a questions-only parser path.

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
| Randomness | `dart:math` `Random.secure()` (per call; no seeded RNG in production) |

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

The reader and the sealed writer enforce exactly these numbers. The **pre-accept
check** in the session is deliberately a few bytes stricter: it reserves the
bounded growth of the mutable metadata in the payload (`revision` up to 10
decimal digits, and the longest `autoLock` storage value). Without that
reservation, a vault accepted exactly at the payload cap at revision 9 would
become one byte too large at revision 10, so a metadata-only preference change
or a password recovery rewrap could fail permanently and leave the vault
unrecoverable. The reservation is about 11 bytes at revision 9 and shrinks as
the revision grows; it is not a cap change and not a content restriction.
`createVault` builds an empty payload, and every accepted edit, import and
auto-lock change is bounded by this check. A password rewrap re-seals the same
accepted data one revision later, which the reservation guarantees fits.

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
- **Both open paths authenticate the whole header.** `unlock` and `recover`
  each verify the same payload AAD, which covers the password salt, the password
  wrap, the recovery salt, the recovery wrap, and the question texts. Damage to
  either block therefore makes **both** paths fail; the reported code differs
  by which check trips first:
  - The damaged block's own unwrap fails as `FailureCode.credentials`
    (password-wrap damage → `unlock` reports `credentials`; recovery-wrap
    damage → `recover` reports `credentials`).
  - The other path gets past its unwrap and then fails the payload AAD as
    `FailureCode.format` (password-wrap damage → `recover` reports `format`;
    recovery-wrap damage → `unlock` reports `format`).
  - Recovery-question text or recovery-salt damage is caught by the payload AAD
    only, so `unlock` reports `format` and `recover` reports `credentials`
    (its recovery wrap no longer verifies under the changed AAD). Password-salt
    damage behaves like password-wrap damage: `unlock` reports `credentials`
    (the derived key no longer matches) and `recover` reports `format`.
  - Payload-ciphertext damage reports `format` on both paths.

  Recovery questions are for forgotten credentials, not for repairing a damaged
  or tampered password block: there is no recovery route back into an envelope
  whose header authentication fails, and this format offers no repair path for
  a corrupt or tampered envelope.


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

Fix round 2 (single-isolate-per-operation code, an earlier Task 1 cycle — not
this document's fix round) re-ran the native checks; the numbers below are from
the amended code.

Run every command below with `--no-uninstall`, on a device or emulator you own
or can throw away that holds **no personal vault**. The test build reuses the
product application id (`com.example.hello_flutter`), and `flutter test`
uninstalls that package afterwards by default, which deletes its private data
directory (`vault.enc`, `vault.previous`). See `docs/testing/native-checks.md`.

`flutter test integration_test/crypto_platform_test.dart -d macos --no-uninstall`
on macOS 27.0.1 (arm64, debug build, 2026-10-22):

| Operation | Time |
| --- | --- |
| `createVault` (2 Argon2id derivations + wraps + payload seal) | 200 ms |
| `unlock` (1 Argon2id derivation) | 81 ms |
| `recover` (1 Argon2id derivation) | 66 ms |
| `seal` (small payload) | < 1 ms |
| `seal` with a 4 MiB note (includes key verify + reseal) | 244 ms |
| Envelope size for the synthetic fixture | 1138 B |

`flutter test integration_test/crypto_platform_test.dart -d emulator-5554 \
  --no-uninstall` (Android 17 / API 37, arm64 emulator, debug build, amended
code, two runs):

| Operation | Time |
| --- | --- |
| `createVault` | 2742–4000 ms (includes JIT warm-up) |
| `unlock` | 406–1072 ms |
| `recover` | 364–558 ms |
| `seal` (small payload) | 166–288 ms |
| `seal` with a 4 MiB note | 1192–2569 ms |
| Envelope size | 1138 B |

Event-loop progress during the seal is checked as a property, not a bound: the
seal-window test asserts that at least one 1 ms sample lands while the seal is
pending and prints the elapsed time and worst gap as diagnostics. The earlier
macOS (8 ms) and emulator (43–59 ms) "longest stall" figures were sampled across
`seal` **and** the following `unlock`, so they were not seal-only measurements
and are not quoted again. The pre-offload 4 MiB seal blocked the loop for
255 ms; that is the regression the isolate offload exists to prevent. The
seal-window check has been run on the host only — the macOS and Android
integration runs of it are **Not run** after this change.

The amended integration test also proves on-device: seal → reseal round-trip,
`rewrapPassword` keeping notes, recovery still working after a password rewrap,
rejection (`FailureCode.format`) of tampered recovery questions, and the
seal-window event-loop progress check.

Round-trip, recovery-key equality, reseal and wrong-password rejection passed on
both platforms.

These numbers are single debug-build measurements on one machine, not a
performance guarantee. Android debug builds run without AOT and the emulator is
not a low-end device, so the unlock figure is an upper-ish bound only.
Run the same integration test on a real low-end Android device before treating
this profile as release-ready; if it is too slow there, change the profile
explicitly (new documented v1 parameters) rather than silently.
