# Security review guidance

Use [the security model](SECURITY_MODEL.md) for OptiMiyoo's assets, attacker
capabilities, trust boundaries, and residual risks. Check the current code when
reviewing a change; the model records a reviewed baseline, not proof that every
later implementation preserves it. General review guidance is in
[AGENTS.md](AGENTS.md).

## Scope and assumptions

Treat game archives, disk images, CUE/playlist descriptors, filenames, existing
output trees, SD configs, and worker requests/results as untrusted. A user choosing
to process a file does not make it safe. Assume a parser exploit can compromise a
confined worker, including a bundled converter, and examine what authority that
worker could obtain from the parent.

Windows, the launching account, and the installed parent code are trusted platform
and distribution inputs. Distinguish attacks that already require replacing that
trusted code from attacks delivered through ordinary game or SD data. Do not
dismiss path substitution or filesystem races simply because they occur locally.

## Security Review Rules

Apply the checks relevant to changed code and follow the affected boundary through
callers and shared helpers. The [code map](SECURITY_MODEL.md#code-map-and-review-use)
identifies the main implementation areas.

1. **Keep confinement intact.** Verify isolation before resuming workers. Review
   changes to process creation, capability SIDs, Job Objects, inherited handles,
   environments, and runtime/tool selection. Isolation failure must not trigger an
   unsandboxed retry. Regular AppContainer and LPAC have different access properties;
   neither should be treated as a guarantee that only staged files are accessible.
2. **Keep authority in the parent.** Validate RPC operations, live session/batch/job
   identities, sequence, and limits. Bind policy grants and conflicts to the
   parent's plan. Worker messages, output paths, success claims, and checksums
   cannot themselves authorize host writes, overwrites, source removal, or SD edits.
   Require parent-owned receipts and independent verification where applicable.
3. **Preserve file identity and ownership.** Trace hostile names and references
   through path resolution, archives, manifests, publication, rollback, and cleanup.
   Check traversal, stream/device syntax, lossy normalization, case collisions,
   reparse points, hard links, and concurrent replacement. Preserve foreign
   references and unrelated content. Verify installed outputs and affected sources
   before removal; never replace failed verification with broad pathname deletion.
4. **Constrain SD changes.** Publish only the exact selected top-level `extlist`
   patch derived from captured original config bytes. Validate config parsing and
   selected profile IDs; exclude extra worker files. Recheck originals and verify
   backups before replacement. Verify writes, attempt recovery on failure, and
   distinguish verified backups and completed updates from incomplete work.
5. **Bound untrusted parsing and work.** Check metadata budgets before allocation,
   actual decompressed sizes, parser depth, entry counts, IPC frames, diagnostics,
   and subprocess limits. Native-converter input and accepted output still need
   validation. CRCs, hashes, receipts, and structural checks do not prove benign
   content or faithful conversion. Limits reduce resource exhaustion; they do not
   establish a universal disk-space or whole-batch resource guarantee.
6. **Keep output and dependencies from gaining authority.** Preserve separation
   between worker display and trusted prompts, escape relevant terminal/control
   text, and protect CSV fields against formula interpretation without changing
   actual path identity. Review new executables, DLL search paths, dependencies,
   downloads, or shell commands for new trust assumptions. Existing provenance
   records are not proof that a parser or modified installation is safe.

## Evidence and validation

For a security finding, identify:

- The attacker-controlled input or capability and the required user interaction.
- The reachable path, precise code location, and boundary or invariant violated.
- Why existing validation, sandboxing, ownership checks, or trusted prompts do not
  prevent the problem, and the concrete confidentiality, integrity, or availability
  impact.
- Whether the finding was reproduced, established by code inspection, or depends
  on an unverified assumption. Include a safe minimal reproduction when practical;
  exploit execution is not required for a well-supported finding.

Assess severity from reachable impact and attacker prerequisites, following the
requested review scope and configured reporting threshold. Clearly distinguish
new regressions, existing issues, and documented limitations. Do not treat an
expected input refusal or an explicitly authorized overwrite as a vulnerability
without a violated boundary; do not dismiss a supported vulnerability solely
because a related limitation is documented.

Use disposable fixtures for malformed input, collisions, reference dependencies,
race attempts, cancellation, and failure/recovery checks. Never test removal,
overwrite, or SD publication against real user data. Report static-only analysis
and unavailable Windows validation honestly. Successful tests do not establish
whole-batch atomicity, guaranteed recovery after power loss, or absence of defects.

When a change adds an input surface or alters execution, authorization, publication,
or recovery, update the relevant security-model section alongside the implementation.
