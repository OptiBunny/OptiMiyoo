# Using OptiMiyoo

Run `OptiMiyoo.bat` from the extracted folder.

[Menus](#menu-guide) · [Game files](#prepare-a-batch) · [Systems](#systems-and-rom-folders) ·
[SD setup](#optional-sd-setup-and-swapping) · [Command line](#command-line)

## Prepare a batch

Put one system's games in `SRC` as loose files, folders, or one ZIP per game.
Keep all discs or tape sides of a game together. Names such as `Game (Disc 1).chd`,
`Game (Disc 2).chd`, or `Game (Side A).tap` determine their order; untagged files
become separate entries. Combine separate side ZIPs or extract and name the sides
first. Keep alternate formats of the same disc in separate batches.

Keep CUE tracks, SBI files, and other companion files with their media. CUE
references must be relative, use forward slashes, and match filename case.

Run the matching menu option, then copy `DST` contents—including `.hidden` when
present—to its [Onion ROM folder](#systems-and-rom-folders) and refresh the game list.
Playlist modes give multi-disc games a visible playlist with media under `.hidden`;
single-media games stay visible. The **C** and **Z** converters produce visible
converted media. `SRC` and `DST` are shared by all modes and are never emptied
automatically.

## Menu guide

Type a number or letter, then **Enter**. Blank Enter uses the displayed default.
In submenus, **B** goes back and **Q** exits. Demo and overwrite controls differ
as described below.

| Main menu | Action |
| --- | --- |
| **1–10** | Create playlists for a [numbered system](#systems-and-rom-folders). Enter selects **1: Amiga**. |
| **C** | Convert C64 NIB/NBZ game ZIPs to visible G64 ZIPs or folders. |
| **Z** | Convert ZX Spectrum IPF → DSK. |
| **S** | Check an SD card's selected cores and enable supported playlist extensions. |
| **D** | Open a demo showcasing the menus, animations, and processing workflow without changing game or SD files. |
| **F** | Switch the bunny and logo between CRT and Smooth. |
| **Q** | Exit. |

### Playlist storage and originals

After choosing a numbered system, select storage:

- **1: Auto** (default) keeps supported Amiga/C64/VIC-20 ZIPs and links to their
  contents. Other ZIPs are extracted; loose files stay loose. Media formats stay unchanged.
- **2: Folders** extracts ZIPs. Use this for games that write to their disk images.

Then select **1: Keep originals** (default) or **2: Remove originals** to start.
Remove applies only to successfully processed originals in `SRC`; failed,
skipped, and unsupported inputs stay. **B** returns to storage settings.
Unsupported or unverified cores show an explanation instead of creating playlists.

### C64 converter: C

Choose **C** separately if you need G64. Put one game's NIB/NBZ or G64 disk
images in each ZIP; this option processes ZIPs only. Menu **2** creates playlists
from the original disk and tape formats, including NIB/NBZ, without conversion.

| Option | Output | Originals in `SRC` |
| --- | --- | --- |
| **1** (default) | ZIP | Keep |
| **2** | ZIP | Remove |
| **3** | Folders | Keep |
| **4** | Folders | Remove |

Each choice starts the batch. NIB/NBZ images convert to G64; existing G64 images
keep their bytes. All converted games stay visible in `DST`, including multi-disk
games. This step creates no playlists or `.hidden` folders.

### ZX converter: Z

Choose **Z** separately if you need IPF → DSK conversion; it creates no playlists.
Menu **10** preserves original ZX formats such as IPF and DSK when the selected
core supports playlists. Stock Onion Fuse does not support playlist loading.

Choose **1: Loose DSK files** or **2: One ZIP per DSK** (default), then Keep or
Remove originals. ZIP suits configurations that list ZIP but lack DSK support.
Some IPF copy-protection details cannot be preserved in DSK.

### Playlists after conversion

If you choose **C** or **Z** first, create a separate batch folder with `SRC` and
`DST`. Copy only the wanted converted files, ZIPs or folders into its `SRC`,
leaving the original input batch intact. Drag the new batch folder onto
`OptiMiyoo.bat`, then choose the numbered system. Its selected core must support playlists.

### Existing outputs and finishing a batch

| Key | If an output already exists |
| --- | --- |
| **Y** | Overwrite this output |
| **N / Enter** | Skip this output |
| **A** | Overwrite all conflicts in this batch |
| **S** | Skip all conflicts in this batch |

**> / <** pages through output paths. Here, **B / Q** also skips the current
output. Skipping keeps both the existing output and its original in `SRC`.

After a batch, **Enter / M** returns to the main menu, **B** reopens its settings,
and **Q** exits.

### Demo and display

In **D**, choose **1** for the full walkthrough, **2** C64, **3** ZX,
**4** playlists, **5** results and overwrite choices, **6** Mio's animation
gallery, or **7** core support and SD setup.

During playback, keys work without Enter: **Space** pauses/resumes; **N / Right / Enter**
go forward; **P / Left** go back; **R** restarts; **F** switches CRT/Smooth.
**B / Q / Esc** returns to demo selection.

## Systems and ROM folders

**S** checks the cores selected on your SD card. The standard profiles are:

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
Amiga IPF playback needs a compatible `capsimg.so` and Kickstart BIOS on the Miyoo.
blueMSX needs its usual `Databases` and `Machines` BIOS folders. These are not included.

## Optional SD setup and swapping

Choose **S** and enter the SD root, such as `E:\`. Setup enables playlist
extensions for the detected cores while keeping games and saves. Unrecognized
configurations remain **UNVERIFIED** and unchanged.

To undo a setup change, copy `config.json` from the corresponding
`OptiMiyoo_Backup_<ID>` folder on the SD card to its original emulator folder.
PlayStation uses `Emu/PSX` for configuration and `Roms/PS` for games.

To swap discs, open the playlist in Onion, then use **RetroArch → Quick Menu →
Disk Control**: eject, select the next image, and insert. C64 tape sides use the
same sequence but may also need keyboard/load commands. DOSBox Pure has its own
disk-selection workflow.

## Command line

Run from the application folder in PowerShell:

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
| `-Root C:\Games\Batch` | Use that folder's `SRC` and `DST`; dragging a folder onto `OptiMiyoo.bat` does the same. |
| `-OnionRoot E:\` | Check the installed core on that SD card. |
| `-SourcePolicy Keep` / `Remove` | Keep originals by default, or remove them after verification. |
| `-Existing Ask` / `Overwrite` / `Skip` | Choose how to handle existing outputs. |
| `-NoAnimation` | Disable decorative animations. |
| `-NoColor` | Use monochrome output. |
| `-DisplayEffect Smooth` | Disable CRT styling. |
