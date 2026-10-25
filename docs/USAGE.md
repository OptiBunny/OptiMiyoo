# OptiMiyoo menu guide

Run **`OptiMiyoo.bat`**. Game files go in `SRC`; finished files appear in `DST`.

[Menus](#menu-guide) · [Game files](#prepare-a-batch) · [Playlists](#create-playlists) ·
[Conversion](#convert-disk-images) · [SD card](#optional-sd-setup-and-swapping) · [Demo](#demo-and-display)

## Menu guide

Type a number or letter, then **Enter**. Enter on its own accepts the displayed
default. In the option menus, **B** goes back and **Q** exits.

On the main menu, **1–10** create playlists; **C** and **Z** convert images only.

| Choose | What it does |
| --- | --- |
| **1–10** | [Create playlists](#create-playlists) for your selected system. |
| **C** | [Convert C64 NIB/NBZ to G64](#c64-converter-c). |
| **Z** | [Convert ZX Spectrum IPF to DSK](#zx-converter-z). |
| **S** | [Set up playlist visibility](#optional-sd-setup-and-swapping) on an Onion SD card. |
| **D** | [Demo](#demo-and-display) showcasing menus, animations, and processing workflows. |
| **F** | Switch the bunny and logo between CRT and Smooth. |
| **Q** | Exit. |

## Prepare a batch

Copy one system's games into `SRC` as loose files or one ZIP per game. Folders can
organize your collection. Keep CUE files with their referenced tracks and matching SBI files.

Give loose discs matching game names and numbered disc labels, even inside folders:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

Tape sides can use names such as `Game (Side A).tap` and `Game (Side B).tap`.
Extract separate side ZIPs first, then use matching filenames or put the images
in one game ZIP. Keep alternate releases and formats of the same disc in separate batches.

## Create playlists

1. Choose your system's number from the [system list](#systems-and-rom-folders).
2. Choose **1: Auto** or **2: Folders** for storage.
3. Choose **1: Keep originals** (default) or **2: Remove originals** to start.

**Auto** keeps supported Amiga, C64, and VIC-20 ZIPs intact; other ZIPs are
extracted. **Folders** extracts ZIPs and suits games that write to their disk
images. Loose files stay loose, and media formats are unchanged in either mode.

Games with two or more images get a playlist in `DST`, with their media under
`.hidden`. Single-media games stay visible without a playlist.

### Using converted images

If you also want playlists for converted images, create a new batch folder with
`SRC` and `DST`. Copy each game's converted disk set into its `SRC`, keeping the
discs together and numbered. For ZX, use loose DSK output or extract the
individual output ZIPs first.

Drag that batch folder onto `OptiMiyoo.bat` and choose the numbered system for
playlists. The selected core must support them.

### Systems and ROM folders

Use the matching folder when copying finished files to your Onion SD card.
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

The app shows playlist availability for each system. With standard Onion cores,
**5, 8, and 10** are unsupported. Use **S** to check the cores selected on your SD card.
C64 also supports TAP/T64 tape-side playlists where the selected core supports them.

## Convert disk images

Both converters save converted media in `DST`. They do not create playlists.

### C64 converter: C

Put one game's NIB/NBZ images in each ZIP in `SRC`, then choose **C**. Existing G64
images in those ZIPs are kept unchanged.

| Choose | Output | Originals |
| --- | --- | --- |
| **1** (default) | ZIP per game | Keep |
| **2** | ZIP per game | Remove after verification |
| **3** | Folder per game | Keep |
| **4** | Folder per game | Remove after verification |

Selecting a mode starts the batch. A multi-disk game stays together in its ZIP or folder.

### ZX converter: Z

Put IPF files or ZIPs containing IPF files in `SRC`, then choose **Z**.

- **1: Loose DSK files** saves each converted image as a `.dsk` file.
- **2: One ZIP per DSK** (default) puts each converted image in its own ZIP.

Next, choose **1: Keep originals** (default) or **2: Remove originals** to start.
Some IPF copy-protection details cannot be preserved in DSK.

## Existing outputs and finishing a batch

If an output already exists, choose:

| Key | Action |
| --- | --- |
| **Y** | Overwrite this output |
| **N / Enter** | Skip this output |
| **A** | Overwrite all conflicts in this batch |
| **S** | Skip all conflicts in this batch |

The choice applies to the listed outputs together. **> / <** pages through their
paths. Here, **B / Q** also chooses Skip. Skipping keeps
the existing output and its original in `SRC`.

Originals are kept unless you selected **Remove**. Removal applies only after
successful output verification; skipped and failed inputs remain in `SRC`.

After processing, review the results. Press **Enter** to return to the main menu
or **Q** to exit. Copy the wanted `DST` contents, including `.hidden` when present,
to the matching [Onion ROM folder](#systems-and-rom-folders), then refresh the game list.

## Optional SD setup and swapping

Choose **S**, enter your SD card's root folder, such as `E:\`, and press **Enter**.
**Esc** cancels. Setup adds supported playlist extensions to the game lists while
preserving the selected cores, games, and saves. Unverified configurations stay unchanged.
Setup returns to the main menu, which then reflects that SD card's playlist support.

To undo a setup change, restore `config.json` from its corresponding
`OptiMiyoo_Backup_<ID>` folder on the SD card to the original emulator folder.

To change discs, launch the playlist in Onion and use **RetroArch → Quick Menu →
Disk Control**: eject, select the next image, and insert. C64 tape sides may also
need keyboard/load commands; DOSBox Pure uses its own disk-selection controls.

## Demo and display

Choose **D** for a demo showcasing the menus, animations, and processing workflows.
It uses sample data without changing game or SD files.

| Choose | Showcase |
| --- | --- |
| **1** (default) | Full walkthrough |
| **2** | C64 conversion |
| **3** | ZX conversion |
| **4** | Playlist creation |
| **5** | Results and overwrite choices |
| **6** | Mio's animation gallery |
| **7** | Core support and SD setup |

During playback, keys work immediately without Enter:

- **Space** pauses or resumes; **R** restarts the selected section.
- **N / Right / Enter** goes forward; **P / Left** goes back.
- **F** switches CRT/Smooth; **B / Q / Esc** returns to demo selection.

## Command line

<details>
<summary>PowerShell examples and options</summary>

Run these from the application folder:

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
| `-Root C:\Games\Batch` | Use that folder's `SRC` and `DST`; dragging it onto `OptiMiyoo.bat` does the same. |
| `-OnionRoot E:\` | Check the selected core on that SD card. |
| `-SourcePolicy Keep` / `Remove` | Keep originals by default, or remove them after verification. |
| `-Existing Ask` / `Overwrite` / `Skip` | Handle existing outputs. |
| `-NoAnimation` | Disable decorative animations. |
| `-NoColor` | Use monochrome output. |
| `-DisplayEffect Smooth` | Disable CRT styling. |

</details>
