# Implementation decisions and costs

These decisions were recorded during the EnCryNote implementation. They do not
replace the user-approved design or turn unavailable checks into passes.

1. **Work in the existing folder on `feat/encrynote`.** This respects the user's
   directory boundary. Cost: a branch does not give concurrent work a separate
   physical checkout.
2. **Coordinator records the initial Git baseline.** Every task then has an exact
   review base. Cost: baseline staging needed explicit inspection to avoid
   including caches, secrets, or unrelated files.
3. **Update connected test fakes when bridge APIs change.** This keeps callers and
   tests complete even when a task's file list omitted a helper. Cost: small
   additional test-helper changes, no product feature.
4. **Keep the unpublished format at v1 with a documented freeze boundary.** No
   migration feature was added for interim prototypes. Cost: early test vaults
   from the pre-freeze layout must be recreated, not silently migrated.
5. **Allow canonical private child directories for vault commits.** Fixed
   filenames, same-parent and containment checks still reject external/symlink
   escapes. This makes tests independent of live data. Cost: more app-private
   directories are accepted, but no external permission is granted.
6. **Clear credential drafts on leaving before the encrypted policy is known.**
   An unlocked vault keeps its chosen inactivity duration. Cost: switching to a
   password manager may require re-entering a partially typed credential.
7. **Continue code work with manual GUI checks explicitly unrun.** The selected
   desktop tool `orca` was absent; no substitute or installation was authorized.
   Cost: native IME, resizing, selection and window behavior may contain unseen
   defects and need manual validation.
8. **Preserve an accepted unsealed edit if sealing itself fails.** The UI redacts
   and freezes, retains required RAM for explicit Retry, and completes an earlier
   lock intent only after success. Cost: key/plaintext lives longer in this
   exceptional error state; it is not advertised as a completed key-free lock.
   App files remain ciphertext.
9. **Do not offer cancellation during the final confirmed import commit.** Earlier
   cancellation releases the handle and aborts before mutation. Cost: Back/Escape
   cannot abort the short finishing step; the UI states that limit instead of
   promising an impossible rollback under every storage failure.
10. **Keep the frozen plan with a checked safety-supersession note.** Current
    `--no-uninstall` and owned-target rules override its historical device
    examples. Cost: moving/removing the plan requires adjusting the safety
    contract test; there is no runtime dependency on that document.
11. **Use operational metadata headroom without changing the v1 wire format.**
    Ten revision digits and the longest auto-lock value are budgeted before
    accepting a state. Cost: a few bytes of usable capacity are reserved, and
    metadata growth beyond that operational width or old raw-cap prototypes is
    not guaranteed; hard limits still apply and no parser cap is invented.

## Final review dispositions

- The operational ten-digit metadata reserve is not an enforced format bound.
  Hard caps and coherent validation/sealing remain enforced; there is no claim
  of unlimited metadata-only growth for arbitrary externally created vaults.
- A stale accepted-revision value after a locked import withdrawal is replaced
  by adoption/load before any authorized mutation. It was left as a non-reachable
  cleanup note, not a reason to widen the final fix wave.
- Verification prose was reconciled at handoff so it does not claim native
  execution of the new seal-window assertion. This changes no app behavior.
- No source was merged, pushed, published or discarded. The feature branch and
  local execution evidence are kept pending the user's integration choice.
