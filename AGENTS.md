# OptiMiyoo repository guidance

OptiMiyoo is a Windows desktop tool for Onion OS game preparation. The supported
launcher uses Windows PowerShell 5.1 on x64 Windows 10 (1809+) / 11, with embedded
C# compiled for .NET Framework. Do not assume PowerShell 7 or modern .NET APIs.

Use [the user guide](docs/USAGE.md) for expected behavior. For security-sensitive
changes, also read [SECURITY.md](SECURITY.md) and the relevant parts of
[the threat model](docs/threat-model.md), then verify those claims against the
current implementation.

## Code Review Rules

### Protect originals and unrelated files

- For processing, publication, and cleanup changes, check normal completion,
  errors, cancellation, and rollback. Removing originals requires the selected
  Remove policy, verified published output, and intact source/dependency checks.
  Skipped, failed, changed, or still-referenced source files must remain protected.
- Overwrite consent does not establish ownership of unrelated destination files.
  Preserve foreign CUE/playlist references and limit replacement and cleanup to
  the planned output. Prefer retaining uncertain files and recovery data to
  bypassing an ownership or identity check.
- SD setup changes only file-type settings authorized through the parent's
  checklist and Apply action or a supported explicit caller selection. Preserve
  other config bytes and verify backups before replacement. Cancellation can
  leave completed changes in place; reports must describe that outcome accurately.

### Preserve the parent/worker boundary

- The parent owns host-file authority and consequential policy decisions. Workers
  propose data through constrained operations. Flag changes that let worker input
  select arbitrary host paths or commands, forge consent, or bypass independent
  verification. Apply the detailed checks in [SECURITY.md](SECURITY.md).

### Preserve Windows compatibility and filename identity

- Check changed scripts and embedded C# against Windows PowerShell 5.1 and its
  .NET Framework runtime. Passing a check in PowerShell 7 alone is insufficient.
- Treat filesystem paths literally. Preserve identity across provider resolution,
  native calls, case comparisons, and display. Reject paths Windows cannot preserve
  rather than silently trimming or normalizing them into a different file.
  Names containing spaces, quotes, Unicode, or shell metacharacters remain data.

### Keep behavior and documentation consistent

- When choices, defaults, controls, or output layouts change, check the actual
  routes, shared menu models, demo, README, and user guide together. Menu-model
  construction and demo playback must not process games or modify SD files.
- Preserve the distinction between conversion, playlist generation, and SD
  file-type settings. A generated playlist does not establish core compatibility;
  a successful conversion does not prove faithful emulation or playability.

## Findings and validation

Report actionable defects with the triggering scenario, affected code, and user
impact. For pull-request reviews, identify what the change introduces or worsens
and distinguish existing issues. These rules supplement ordinary correctness
review; they are not a reason to overlook defects outside the examples above.
Avoid style-only findings unless the style causes a concrete problem.

Use relevant checks available in the checkout. Validate file-changing behavior
with disposable collections and SD directory fixtures, not a user's real `SRC`,
`DST`, or card. Include failure and cancellation cases when those paths change.
State what ran, on which runtime, and what remains unverified; do not claim Windows
runtime behavior from static inspection or a test on another platform.

For documentation-only changes, check links, examples, and agreement with the
implementation. Preserve existing file encodings, BOMs, and line endings when
editing; `.gitattributes` intentionally disables automatic text conversion.
