# OptiMiyoo user guide

Run **`OptiMiyoo.bat`**. Put game files in `SRC`; collect finished files from `DST`.

[Menus](#menu-guide) · [Game files](#prepare-a-batch) · [Playlists](#create-playlists) ·
[Conversion](#convert-disk-images) · [SD card](#optional-sd-setup-and-swapping) · [Demo](#demo-and-display)

## Menu guide

Type a number or letter, then **Enter**. Enter alone accepts the displayed default.
In option menus, **B** goes back and **Q** exits.

| Choose | Action |
| --- | --- |
| **1–10** | [Create playlists](#create-playlists) without converting media. |
| **C** | [Convert C64 NIB/NBZ to G64](#c64-converter-c). |
| **Z** | [Convert ZX Spectrum IPF to DSK](#zx-converter-z). |
| **S** | [Set up playlist visibility](#optional-sd-setup-and-swapping) on an Onion SD card. |
| **D** | [Demo](#demo-and-display) showcasing menus, animations, and workflows. |
| **F** | Switch the bunny and logo between CRT and Smooth. |
| **Q** | Exit. |

## Prepare a batch

Copy one system's inputs into `SRC`, using the layout for your main-menu option below.

To use a separate batch folder, create `SRC` and `DST` inside it and drag the
folder onto `OptiMiyoo.bat`.

### Numbered options: playlists

Use loose files or one ZIP per game. Keep CUE files with their referenced tracks
and matching SBI files.

Loose discs need matching game names and numbered labels, even inside folders:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

Use `Game (Side A).tap` and `Game (Side B).tap` for tape sides. Extract separate
disc or side ZIPs first, then name the files or combine the images into one game ZIP.
Keep alternate releases and formats of the same disc in separate batches.

### C: C64 conversion

Put each game's NIB/NBZ images in a ZIP, then copy the ZIPs into `SRC`. Existing
G64 images can be included and are kept unchanged. **C reads ZIPs only**; loose
NIB/NBZ files must be zipped first.

Name each ZIP after its game: `Game.zip` produces `Game.zip` or `Game/` in `DST`.
The images inside do not need disc or side numbering for conversion.

### Z: ZX conversion

Copy loose `.ipf` files or ZIPs containing IPF images into `SRC`. ZIPs can contain
one or several images; **each IPF is converted separately**. Disc or side
numbering is not required. Files and ZIPs can also be in subfolders.

## Create playlists

Choose your [system number](#systems-and-rom-folders), then storage:

- **1: Auto** (default) keeps supported Amiga, C64, and VIC-20 ZIPs intact and
  extracts other ZIPs.
- **2: Folders** extracts ZIPs. Use this for games that write to their disk images.

Choose **1: Keep originals** (default) or **2: Remove originals** to start.
Loose files stay loose; media formats remain unchanged.

Multi-disc games get a playlist in `DST` and media under `.hidden`. Single-media
games stay visible without a playlist. Converted images can be used as inputs
in a separate batch, following the same [grouping rules](#numbered-options-playlists).

### Systems and ROM folders

**Enter** at the main menu selects **1: Amiga**.

| Menu | System | Onion folder |
| --- | --- | --- |
| **1** | Amiga | `Roms/AMIGA` |
| **2** | Commodore 64 | `Roms/COMMODORE` |
| **3** | PlayStation | `Roms/PS` |
| **4** | Sega CD / Mega-CD | `Roms/SEGACD` |
| **5** | Amstrad CPC | `Roms/CPC` |
| **6** | MSX / MSX2 | `Roms/MSX` |
| **7** | VIC-20 | `Roms/VIC20` |
| **8** | PC Engine CD | `Roms/PCECD` |
| **9** | MS-DOS | `Roms/DOS` |
| **10** | ZX Spectrum | `Roms/ZXS` |

With standard Onion cores, **5, 8, and 10** do not support playlists. **S** checks
the cores on your SD card. C64 tape-side support is shown in its playlist menu.

## Convert disk images

**C** and **Z** save converted media in `DST` without creating playlists.

### C64 converter: C

After [preparing the C64 ZIPs](#c-c64-conversion), choose **C** and a mode:

| Choose | Output | Originals |
| --- | --- | --- |
| **1** (default) | ZIP per game | Keep |
| **2** | ZIP per game | Remove |
| **3** | Folder per game | Keep |
| **4** | Folder per game | Remove |

Selecting a mode starts the batch.

### ZX converter: Z

After [preparing the IPF inputs](#z-zx-conversion), choose **Z** and an output format:

- **1: Loose DSK files**
- **2: One ZIP per DSK** (default)

Choose **1: Keep originals** (default) or **2: Remove originals** to start.
Some IPF copy-protection details cannot be preserved in DSK.

## Existing outputs and finishing a batch

When an output exists, your choice applies to the listed outputs together:

| Key | Action |
| --- | --- |
| **Y** | Overwrite this output |
| **N / Enter** | Skip this output |
| **A** | Overwrite all conflicts in this batch |
| **S** | Skip all conflicts in this batch |

**> / <** pages through paths. At this prompt, **B / Q** also chooses Skip.
Skipped outputs stay unchanged. Originals stay in `SRC` unless you chose
**Remove** and their outputs passed verification; skipped and failed inputs are kept.

Review the results, then press **Enter** for the main menu or **Q** to exit.
Copy the wanted `DST` contents, including `.hidden` when present, to the matching
[Onion ROM folder](#systems-and-rom-folders) and refresh the game list.

## Optional SD setup and swapping

Choose **S**, enter the SD root (for example `E:\`), and press **Enter**.
**Esc** cancels. Setup adds supported playlist extensions while preserving your
selected cores, games, and saves.

To undo a change, restore `config.json` from its corresponding
`OptiMiyoo_Backup_<ID>` folder on the SD card to the original emulator folder.

To swap discs, launch the playlist and open **RetroArch → Quick Menu → Disk
Control**: eject, select the next image, and insert. C64 tape sides may also need
keyboard/load commands; DOSBox Pure uses its own disk-selection controls.

## Demo and display

**D** opens a demo showcasing menus, animations, and workflows without changing
game or SD files.

| Choose | Showcase |
| --- | --- |
| **1** (default) | Full walkthrough |
| **2** | C64 conversion |
| **3** | ZX conversion |
| **4** | Playlist creation |
| **5** | Results and overwrite choices |
| **6** | Mio's animation gallery |
| **7** | Core support and SD setup |

During playback, keys work without Enter:

- **Space** pauses/resumes; **R** restarts the section.
- **N / Right / Enter** goes forward; **P / Left** goes back.
- **F** switches CRT/Smooth; **B / Q / Esc** returns to demo selection.

## Command line

<details>
<summary>PowerShell examples and options</summary>

Run from the application folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\make_playlists.ps1 `
  -System AMIGA -Storage Folders
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\make_playlists.ps1 `
  -C64Convert -C64Mode Keep
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\make_playlists.ps1 `
  -ZXConvert -ZXFormat ZipDSK
```

| Option | Purpose |
| --- | --- |
| `-Root C:\Games\Batch` | Use that folder's `SRC` and `DST`. |
| `-OnionRoot E:\` | Check that SD card's selected cores. |
| `-SourcePolicy Keep` / `Remove` | Choose what happens to verified originals. |
| `-Existing Ask` / `Overwrite` / `Skip` | Handle existing outputs. |
| `-NoAnimation` | Disable decorative animations. |
| `-NoColor` | Use monochrome output. |
| `-DisplayEffect Smooth` | Disable CRT styling. |

</details>
