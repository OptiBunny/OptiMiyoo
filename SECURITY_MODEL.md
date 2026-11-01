# OptiMiyoo security model

Last reviewed: 2026-11-01.

This model covers the Windows desktop application: playlist creation, C64 and
ZX Spectrum conversion, Onion SD setup, and their shared runtime. It describes
existing controls, the properties security reviews should preserve, and known
limits. It is not a security certification or a list of confirmed vulnerabilities.
Update it when a change alters inputs, execution privileges, or file authority.

## Assets and security goals

| Asset | Required protection |
| --- | --- |
| Original games in `SRC`, including CUE tracks and playlist dependencies | Preserve bytes unless the user selects Remove and the parent verifies the affected source set and its published outputs. |
| Existing `DST` games, playlists, and unrelated files | Replace only planned, owned output with appropriate overwrite authority; preserve unrelated content and references. |
| Host files, credentials, and application installation | Untrusted data and confined workers must not acquire arbitrary host read, write, delete, or command execution authority. |
| SD-card configs, games, and backups | Apply only selected file-type settings; preserve other settings and game files; verify backups before replacing configs. |
| User decisions and result reports | Take consequential choices in the trusted parent; do not treat worker text or claimed success as authorization or verified results. |
| Host availability | Bound hostile parsing, subprocesses, IPC, and resource use; fail safely when limits or filesystem checks fail. |

## Attacker model and assumptions

An attacker can supply a game ZIP, disk image, CUE/playlist descriptor, filename,
directory layout, or SD-card config that a user chooses to process. Selecting a
file does not make its contents trustworthy. Existing destination files and
references also require validation. Consider changes to these filesystem trees
between inspection and use, including links, renames, and replacement files.

Assume a parser exploit can give an attacker control of a confined application,
archive, or native-converter worker. Such a worker can forge requests, diagnostics,
completion claims, and proposed outputs. The parent must independently establish
the authority and evidence needed for every host-side effect.

The installed application, system profiles, bundled executables and DLLs, and
Windows/PowerShell/.NET are trusted distribution and platform inputs. Parent
planning helpers, validators, native interop, and prompt code are all part of
the trusted computing base, even when the same helper is also used in a worker.
The parent runs with the launching account's authority. The application and its
scratch area require ordinary folders on a writable local NTFS drive.

This model does not claim protection against a compromised parent or installation,
an administrator/kernel attacker, or an account already able to replace trusted
code. Filesystem race defenses still matter within the supported workflow;
these exclusions do not excuse a path escape caused by malicious input data.
Emulator execution on the Miyoo and manual copying of output are outside the
application's isolation boundary. There is no hosted service or remote-user
authentication boundary in this application.

## Data flow and trust boundaries

1. **Launch and staging.** The trusted launcher starts the parent coordinator.
   Its local command environment enables the required CMD extensions and clears
   any inherited `ERRORLEVEL` variable, so exit status comes from the child process.
   These changes end with the batch launcher and do not change the caller's settings.
   The parent stages a fixed list of installed scripts and literal compiled
   helpers. Compiled work-directory literals escape Unicode line separators and
   control characters without changing the path or its confinement scope. Application
   scratch lives under `data/temp`; process-local temporary environment changes are
   restored when the scope closes.
2. **Application worker.** Menus and processing scripts run in a fresh,
   zero-capability Windows AppContainer. Staged code/control files are read-only
   to the worker; its disposable work area is writable. Original `SRC`/`DST`
   authority remains with the parent. The child communicates through bounded RPC.
3. **Archive and converter workers.** The parent brokers fixed archive operations
   and native tools into separate sandboxes. Workers process staged bytes and
   return data. They do not select arbitrary host commands or publication paths.
4. **Output publication.** After application-worker shutdown, the parent checks
   proposed outputs against its plan, source snapshots, ownership checks, and
   receipts. Accepted bytes pass through private publication staging into `DST`.
   Only then can eligible originals be removed under the selected policy.
5. **SD setup.** The parent captures selected config files and the user's
   Keep/On/Off intentions, computes the permitted changes, and verifies the
   isolated updater's results before writing the card and its backups.
6. **Display and reports.** Worker display is untrusted. The parent owns policy
   prompts, final result records, and the CSV/log files beside `SRC` and `DST`.

## Controls and review invariants

### Isolation and broker authority

The application process starts suspended, enters a constrained Windows Job
Object, and has its AppContainer token verified before execution resumes.
It receives a rebuilt environment, restricted pipe handles, and child-process
restrictions. Failure to establish isolation must stop the operation, without
an unconstrained fallback. Application sessions, native jobs, and archive helper
scratch roots retain an exclusive native creation claim through staging and use.
Cleanup releases the claim, then verifies its recorded identity before deletion;
it must not adopt a replacement directory after startup failure or cancellation. Defaults include 1 GiB of memory and 1,800 CPU seconds;
the latter is not a wall-clock timeout.

Menu-only sessions have no collection broker or native-job broker. They can ask
for a parent-owned policy choice, hand off that matching selection, choose SD
setup, or change the display preference. An accepted processing handoff stops
the menu worker before the parent creates a fresh session and snapshots `SRC`
and `DST`. Collection staging never runs alongside that menu worker. The new
processing worker receives the independently planned batch; the original root
and source policy remain parent-owned. Opening menus or using SD setup does not
require readable game collections. During approved batch preparation, the parent
polls cancellation through both collection inventories, path checks, and file-copy
chunks. Cancellation stops preparation before any processing worker starts or
output is published; the session retains uncertain files if safe cleanup fails.

RPC has an operation allowlist, bounded frames and JSON depth, request sequencing,
and time limits for incomplete messages. Batch policy grants must match the
approved operation, system, and storage selection. Job, conflict, task, and batch
identifiers must refer to live parent-owned state. A worker must not manufacture
overwrite consent, select host deletion targets, or supply executable code.

Native jobs use fixed installed executables, runtime files, and argument patterns.
The parent binds allowed tools to the batch operation. NIBTools and HxC x64 use
Low Privilege AppContainer (LPAC); HxC x86 uses regular AppContainer. All use
zero capability SIDs, process/resource limits, and independent wall timers.
Keep these distinct isolation modes explicit when reviewing fallback paths.

Regular AppContainer is not LPAC, and neither is a hermetic virtual machine.
Resources accessible under Windows policy may remain accessible; do not infer
that only OptiMiyoo's staged paths can ever be read. Workers receive no network
capabilities, but the parent itself is not sandboxed by these worker controls.

### Hostile media, archives, and descriptors

ZIP metadata is inspected and bounded before creating the full entry collection.
Separate media/floppy budgets bound entry counts, metadata, individual files,
and expanded totals. Decompression also checks actual lengths and CRCs. A high
compression ratio alone is not rejected because valid disk images can compress
well. Review both declared sizes and actual expansion against
[the archive limits](app/shared/archive_limits.ps1).

Archive payload workers write numbered temporary files, not paths taken from
member names. The parent validates reports and rehashes payloads before import.
Member validation rejects traversal, rooted/stream syntax, reserved names,
case-insensitive collisions, and file/directory overlaps, including empty-directory
paths. Derived game paths and CUE/playlist references must remain within their
permitted roots and agree with the planned media and output layout.

Archive manifests, broker collection inventories and output member maps, parent
source-ownership records, destination directory indexes, and conversion/playlist
descriptor caches use ordinal, case-insensitive identity. Linguistic equality must not merge distinct
Windows filenames, including composed and decomposed Unicode spellings. Newly
discovered CUE/playlist files require their own reference check; a cache entry for
another spelling cannot authorize replacement of files they reference. These
ownership checks also prevent an existing playlist's reference to one Unicode
spelling from authorizing replacement or retirement of another. These identity
checks do not override conservative media-group ambiguity checks;
ambiguous loose titles can still be refused while unrelated jobs proceed.
Archive playlist ordering keeps natural disk-number sorting and uses an ordinal
final tie-breaker for linguistically equal filenames, so the parent and its
PowerShell 5.1 worker produce the same playlist bytes for those names.

Playlist dependency checks consider representable literal, right-trimmed, and
fully trimmed spellings of each non-comment line. A space before `#` can belong
to a filename; it does not make the original line a comment. Whitespace and
archive-member interpretations share the same bounded candidate budget.

NIB/NBZ decoding validates bounded input and expanded sizes, track tables, and
supported track numbers before native conversion. The trusted parent independently
validates the bytes from its held input stream. Declared track 85 is refused
because the bundled converter does not process it; the whole input is retained
instead of silently dropping that track. These checks do not prove faithful
conversion. IPF validation streams
record lengths and CRCs, including DATA payload bounds and supplied checksums,
from a held input stream before HxC inspection or conversion. The trusted native
broker independently applies the same checks, so a worker cannot skip input
integrity validation. Every IMGE/TRCK descriptor must have a nonzero identifier
with a matching DATA record, in either order. Missing references stop the whole
input before a converter can silently drop a track. At most 65,536 distinct
nonzero identifiers are retained; this is a bookkeeping limit, not a disk-geometry
limit. Reads and cancellation polling are bounded, including the final reference
check, and validation restores the borrowed stream position. Paired zero-length
DATA for empty/noise tracks, unknown extension records, extended metadata tails,
and absent optional DATA checksums remain supported. These checks establish
container and reference integrity, not complete track semantics or faithful conversion.

G64/DSK structure checks and parent-owned receipts bind accepted converted bytes
to the batch, converter, input hash, output hash, and length. Passthrough files
must match captured source bytes. A worker's successful exit or claimed checksum is insufficient evidence.
The trusted host still parses metadata, names, descriptors, and selected media
structures: those parsers remain attack surfaces.

### Publication, overwrite, and removal

Keep originals is the default. Source-policy and overwrite choices come from the
parent's trusted prompts or explicit supported caller policy, not worker output.
Overwrite approval does not waive checks for foreign references or unrelated
contents. The parent derives conflicts and allowed output names independently.

Before publication, the parent polls cancellation while copying and hashing
private output bytes, enumerating folder members, and at archive verification
checkpoints. Cancellation releases unpublished staging and keeps the affected
originals and prior output. Archive checks follow worker progress; this does not
promise a fixed response time from a silent worker. Installation and rollback
retain their uninterrupted transaction boundaries, and ordinary I/O failures
remain failures even when cancellation is also requested.

Before moving an existing output to its transaction backup, publication captures
its Windows alternate filename through the same handle used for the rename.
Foreign CUE/playlist checks retain that alias while the original name is absent;
captured folder aliases also protect descendants. Failure to establish this
identity stops replacement.

Folder verification compares actual enumerated relative filenames with the
planned member names, as well as file counts and hashes. This check applies to
private publication copies, installed folders, and outputs used to authorize
source removal. Publication verifies installed members through retained file and
ancestor leases, checking length and hash through the same open stream and then
checking the enumerated names. The caller owns these leases before verification
starts and keeps them through old-output backup removal and commit recording;
cleanup can release them even if engine Stop interrupts a function return.
The leases prevent changes to verified members during that interval. They do not
freeze every possible new directory entry or protect files after publication ends.
The final removal check independently enumerates names while its verified file
and ancestor leases are held. A path resolving through a Windows alternate
filename does not prove that the planned directory layout was preserved.

Path handling must preserve containment and object identity throughout reads,
staging, replacement, rollback, and cleanup. Existing controls include pinned
ancestor/file handles, reparse-point rejection, hard-link checks where identity
matters, exact manifests, inventory checks, and hash verification. Path strings
alone are not durable authority. Failure to verify a path must not lead to broad
recursive deletion or an unchecked pathname fallback.

Private publication containers are created exclusively with a protected access
list and a native handle returned by the creation operation. A directory lease
protects that identity through installation and rollback. After releasing the
lease, bounded native cleanup checks the captured identity again; a substituted
container or failed verification must be retained, not adopted or recursively
removed by pathname.

Selected roots are checked in their original and provider-resolved spelling before
lossy normalization. Ordinary path components ending in a dot or ASCII space are
refused; Unicode whitespace must retain its identity on the active runtime. Native
file leases check lexical ancestor prefixes before directory APIs can normalize
them into different folders. An unrepresentable ancestor must stop the operation,
not cause a different directory to be checked or pinned.

Original removal requires successful publication and verification of all affected
owning jobs and dependencies. Recheck installed output bytes, source bytes, and
retained CUE/playlist references before deleting through held source handles.
Skipped, failed, changed, or still-referenced sources must not be removed just
because another job succeeded. Ambiguous ownership must preserve the affected
files. Preserve recovery data when rollback or safe cleanup cannot complete.

### SD-card settings

SD setup edits known file-list extensions in fixed profile config paths. It does
not check, install, or switch emulator cores. Core compatibility information is
not authority to change other SD files or execute a card's `launch.sh`. SD path
prompts preserve literal characters inside quotes, including when an invalid path
is shown again for correction. Retrying must not select a normalized sibling.

Selections begin with Keep. The parent validates fixed profile IDs and On/Off
intentions and computes the exact permitted config bytes from captured originals.
Only the intended top-level `extlist` value may change; unrelated settings and
bytes must be preserved. Config parsing rejects malformed UTF-8/JSON, ambiguous
or duplicate properties, excessive nesting, invalid extension tokens, and files
over the configured size limit. Extra files created by the updater are not imported.

Before publication, validate every selected proposed config, reacquire write
authority for the original, and compare it with the captured bytes. Reject linked
or multiply hard-linked write targets. Create a new backup set and retain the
native handle returned by exclusive creation, so a competing directory cannot
be adopted between creation and use. Verify the original bytes in that backup
before overwriting, verify the replacement, and attempt
restoration if the write fails. Current backups use
`Backups/OptiMiyoo_<timestamp>/Emu/<system>/config.json`. Recovery advice must
distinguish verified backups from partial or unverified files. If restoration fails,
the diagnostic identifies the affected config, its verified backup, and the count
of earlier updates kept. A later stream-close error must not replace that advice;
cleanup still attempts to release every held lease.

### Terminal output and diagnostics

The terminal relay filters worker control sequences. Trusted prompts pause/drain
worker output and take keyboard ownership so a child cannot answer its own policy
question. Host prompt paths and result/log lines escape selected control and
bidirectional characters; filesystem operations retain the original path identity.

CSV export protects formula-like string fields, including prefixed whitespace
and full-width operator forms. CSV quoting alone is insufficient. Verified
reports use parent results and new, unique filenames. Logs and reports can contain
local paths, filenames, and processing details; they are not anonymized. Ordinary
hostile text can still mislead a reader outside the trusted prompts.

## Threat scenarios to consider in reviews

| Attacker action | Security property to check |
| --- | --- |
| Supply ZIP traversal names, conflicting case, ambiguous ZIP64 metadata, or an expansion bomb | Bound parsing and resource use; no extraction/publication outside the permitted namespace. |
| Trigger an IPF/NIB/NBZ decoder exploit | Keep converter authority confined; no unsandboxed retry or arbitrary command through the broker. |
| Forge RPC completion, reuse a stale ID, or substitute staged output | Require active parent-owned authority, matching receipts/manifests, and output verification after worker shutdown. |
| Use a CUE/playlist reference or output-name collision to target another game | Preserve unrelated output and dependencies; resolve references within permitted roots. |
| Swap a file, directory, junction, or hard link between planning and cleanup | Verify held object identity and inventories; preserve files when checks cannot establish safety. |
| Forge an SD patch, corrupt config JSON, or redirect a backup directory | Publish only the exact selected patch to verified config paths after a verified backup. |
| Put terminal controls, bidi text, or spreadsheet formulas in names or diagnostics | Keep display/export data separate from trusted prompts and filesystem authority. |
| Cause cancellation, resource exhaustion, device removal, or a failed rollback | Report partial outcomes accurately; retain recoverable originals/backups and avoid unsafe cleanup. |

## Residual risks and scope limits

- Hashes, CRCs, and receipts establish consistency or provenance of observed bytes.
  They do not authenticate a game, prove faithful conversion, guarantee playability,
  or make output safe for another emulator to parse.
- Publication is per output job; SD changes are per config. An entire batch/card
  update is not atomic. Cancellation leaves completed work in place, and originals
  already removed are not restored. Power loss, forced termination, failing media,
  and failed restoration can still require recovery.
- File leases and inventory monitoring reduce races. The inventory guard is a
  change detector, not an atomic lock against every namespace mutation by a local
  process. Detected changes and unavailable verification must fail closed.
- Resource limits reduce denial-of-service risk but do not guarantee disk space
  or bound every aggregate batch cost. There is no general scratch-disk quota;
  interrupted operations or safe-cleanup failures can leave temporary data behind.
- Bundled-tool provenance and source/build details are recorded in
  [third-party documentation](third_party/README.md). Those records and fixed
  staging lists do not authenticate an already-modified installation or eliminate
  dependency vulnerabilities. New dependencies, executables, downloads, or launch
  paths need a fresh review of the trust boundary.

## Code map and review use

| Area | Primary implementation |
| --- | --- |
| Startup, worker confinement, RPC, trusted decisions | [Host](app/runtime/application_host.ps1), [session](app/runtime/application_session.ps1), [prompts](app/runtime/application_prompts.ps1) |
| Staged code and local scratch | [Staging](app/runtime/application_staging.ps1), [portable storage](app/shared/portable_storage.ps1) |
| Output authority and original removal | [Broker](app/runtime/application_broker.ps1), [source policy](app/shared/source_policy.ps1), [conversion layout](app/shared/conversion_layout.ps1), [playlists](app/playlists/make_playlists.ps1) |
| Native jobs and output receipts | [Job broker](app/runtime/application_jobs.ps1), [native sandbox](app/shared/native_sandbox.ps1), [native capture](app/shared/native_process.ps1) |
| ZIP/media processing | [Archive broker](app/runtime/application_archive.ps1), [archive sandbox](app/shared/archive_sandbox.ps1), [ZIP integrity](app/shared/zip_integrity.ps1), [media validation](app/shared/media_validation.ps1) |
| SD selection, patching, backups | [SD session](app/runtime/application_sd.ps1), [config handling](app/onion/core_support.ps1), [SD updater and leases](app/onion/prepare_onion.ps1) |
| Display and export handling | [Output safety](app/shared/output_safety.ps1), [display](app/ui/display.ps1) |

For each finding, identify the attacker-controlled input, reachable code path,
violated boundary or invariant, and concrete impact. Distinguish malicious-input
attacks from cases that already require replacing trusted installed code. Expected
input refusals and explicitly authorized overwrites are not vulnerabilities by
themselves. Changes to the controls above should be checked with relevant hostile
inputs and failure cases; this document is not evidence that those checks passed.
