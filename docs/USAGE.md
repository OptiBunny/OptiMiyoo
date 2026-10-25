# Using OptiMiyoo

Extract the complete ZIP to a writable folder and run `OptiMiyoo.bat`.
Requires Windows 10 version 1809 or newer / Windows 11 x64, Windows PowerShell
5.1 and the built-in .NET Framework. Converter tools are included;
ROMs, BIOS files, and Onion cores are not.

[Menus](#menu-guide) · [Game files](#prepare-a-batch) · [Systems](#systems-and-rom-folders)
· [SD setup](#optional-sd-setup-and-swapping) · [Display](#display-effects) · [Command line](#command-line)

## Menu guide

Type a number or letter, then **Enter**. Blank Enter uses the displayed default.
In submenus, **B** goes back and **Q** exits; demo playback and overwrite prompts
have their own controls below.

| Main menu | Action |
| --- | --- |
| **1–10** | Prepare playlists for a [numbered system](#systems-and-rom-folders). Enter selects **1: Amiga**. |
| **C** | Convert C64 NIB/NBZ → G64. Use main-menu **2** for C64 disk or TAP/T64 playlists. |
| **Z** | Convert ZX Spectrum IPF → DSK, independently of playlist support. |
| **S** | Check an SD card's selected cores and enable supported playlist extensions. |
| **D** | Preview the workflow without changing game or SD files. Animations are optional. |
| **F** | Switch between CRT and Smooth when animated effects are enabled. |
| **Q** | Exit. |

### Playlist storage and originals

Choose a numbered system, then storage:

- **1: Auto** (default) keeps supported Amiga/C64/VIC-20 ZIPs, using playlist
  references to files inside them. Other ZIPs are extracted; loose files stay loose.
  NIB/NBZ content converts to G64 where needed.
- **2: Folders** extracts ZIPs. Use this when games write to their disk images.

Then choose **1: Keep originals** (default) or **2: Remove originals** to start.
**B** returns to output settings. ZX uses the same originals screen.

**Remove** deletes successfully processed originals from `SRC`. Failed, skipped,
or unsupported inputs are kept. Keep originals until you have tested the games.
Unsupported or unverified cores show an explanation instead of creating playlists.

### C64 converter: C

| Option | Output | Originals in `SRC` |
| --- | --- | --- |
| **1** (default) | ZIP | Keep |
| **2** | ZIP | Remove |
| **3** | Folders | Keep |
| **4** | Folders | Remove |

Each choice starts the batch directly. Existing G64 images are kept as they are;
multi-disk ZIPs receive a playlist and media under `.hidden`.

### ZX converter: Z

Choose **1: Loose DSK files** or **2: One ZIP per DSK** (default), then originals
handling. ZIP suits configurations that list ZIP but lack DSK. Some IPF
copy-protection details cannot be preserved in DSK.

### Demo: D

| Option | Preview |
| --- | --- |
| **1** (default) | Full walkthrough |
| **2** | C64 conversion |
| **3** | ZX conversion |
| **4** | Playlists and disk order |
| **5** | Results, overwrite choices, skips and errors |
| **6** | Mio's animation gallery |
| **7** | Core support and Onion SD setup |

During playback, press keys directly: **Space** pause/resume, **N / Right / Enter**
next, **P / Left** previous, **R** restart, **F** CRT/Smooth.
**B / Q / Esc** returns to demo selection; there, **B** returns to the main menu
and **Q** exits.

### After a batch and existing outputs

After a batch, **Enter / M** returns to the main menu, **B** reopens its settings,
and **Q** exits. For existing outputs, playlists, C64, and ZX use the same choices:

| Key | Action |
| --- | --- |
| **Y** | Overwrite this output |
| **N / Enter** | Skip this output |
| **A** | Overwrite all conflicts in this batch |
| **S** | Skip all conflicts in this batch |

**> / <** pages through the output paths. In this prompt, **B / Q** also skips the
current output. Skipping keeps both the existing output and its original in `SRC`.

## Prepare a batch

Use one system per batch. Put games in `SRC` as loose files, game folders, or
one ZIP per game. Run the matching menu route and review the results.
Copy `DST` contents, including `.hidden`, to the system's ROM folder below,
then refresh Onion's game list.

`SRC` and `DST` are shared by all modes and never emptied automatically. Old
copies already on the SD card may appear alongside new playlists.

## Systems and ROM folders

These are the standard profiles. **S** checks the cores selected on your SD card.

| Menu | System | Onion folder | Default core | Playlist support |
| --- | --- | --- | --- | --- |
| **1** | Amiga | `Roms/AMIGA` | PUAE 2021 | `.m3u` |
| **2** | Commodore 64 | `Roms/COMMODORE` | VICE x64 | `.m3u`, including TAP/T64 sides |
| **3** | PlayStation | `Roms/PS` | PCSX ReARMed | `.m3u` |
| **4** | Sega CD / Mega-CD | `Roms/SEGACD` | PicoDrive | `.m3u` |
| **5** | Amstrad CPC | `Roms/CPC` | CrocoDS | Unsupported disk swapping |
| **6** | MSX / MSX2 | `Roms/MSX` | blueMSX | `.m3u` |
| **7** | VIC-20 | `Roms/VIC20` | VICE xvic | `.m3u` for disks |
| **8** | PC Engine CD | `Roms/PCECD` | Beetle PCE Fast | Unsupported disk swapping |
| **9** | MS-DOS | `Roms/DOS` | DOSBox Pure | `.m3u8` |
| **10** | ZX Spectrum | `Roms/ZXS` | Stock Onion Fuse | Unsupported playlist loading |

Unsupported playlist profiles can still run ordinary games in their emulator.
Amiga IPF playback requires a compatible `capsimg.so` and Kickstart BIOS on the
Miyoo; these are not included. blueMSX needs its usual `Databases` and `Machines`
BIOS folders.

## Naming and storage

Keep all discs or tape sides together. Use names such as `Game (Disc 1).chd`,
`Game (Disc 2).chd`, or `Game (Side A).tap`. Disc/side labels determine order;
untagged files become separate entries. Combine separate side ZIPs or extract
and name the sides first. Keep alternate formats of a disc in separate batches.

Two or more playable images produce a visible playlist with media under `.hidden`.
Single-media games remain visible. Keep CUE tracks, SBI files and other companions
with their media; they do not count as extra discs. CUE references must be relative,
use forward slashes, and match filename case.

## Optional SD setup and swapping

Choose **S** and enter the SD root, such as `E:\`, to enable playlist support for
the detected cores. Games and saves are kept. Unrecognized configurations remain
**UNVERIFIED** and unchanged. Enter reuses a previous SD root only when shown.

Backups are stored in uniquely named `OptiMiyoo_Backup_<ID>` folders on the SD card.
To undo a change, copy the backed-up `config.json` to its original emulator folder.
PlayStation uses `Emu/PSX` for configuration and `Roms/PS` for games.

To swap discs, open the playlist in Onion, then use RetroArch **Quick Menu → Disk
Control**: eject, select the next image, and insert. C64 tape sides use this sequence
too, but may need keyboard/load commands; tape support is checked separately.
DOSBox Pure also has its own disk-selection workflow.

## Display effects

The bunny makes a brief idle gesture every 12 seconds. Choose **D → 6** to preview
its expressions and movements.

For continuous decorative animations, run the application script without `-NoAnimation`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\make_playlists.ps1 `
  -DisplayEffect Smooth
```

In this mode, **F** toggles CRT/Smooth styling on the bunny. Use `-NoAnimation` to
stop decorative animation, or add `-IdleAnimations` for the usual occasional gestures.

## Command line

From the application folder in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\make_playlists.ps1 `
  -System AMIGA -Storage Folders
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\make_playlists.ps1 `
  -ZXConvert -ZXFormat ZipDSK
```

| Option | Purpose |
| --- | --- |
| `-Root C:\Games\Batch` | Use that folder's `SRC` and `DST`; dragging a folder onto `OptiMiyoo.bat` does the same. |
| `-OnionRoot E:\` | Check an installed core. |
| `-SourcePolicy Keep` / `Remove` | Keep by default, or remove originals after verification. |
| `-Existing Skip` | Skip existing outputs. |
| `-DisplayEffect Smooth` | Disable CRT styling. |
| `-NoAnimation` / `-NoColor` | Freeze animation / disable colors. |
| `-IdleAnimations` | With `-NoAnimation`, allow a brief bunny gesture every 12 seconds in idle menus. |
| `-Preview -PreviewSection Bunny` | Show the bunny's expressions and idle gestures without processing files. |
| `-NoPause` | Finish without waiting for a keypress. |

Bundled components have separate licenses. CAPSIMG's included license restricts
commercial use; see [licenses and source details](../third_party/README.md).
