# OptiMiyoo user guide

## Menu guide

Run **`OptiMiyoo.bat`**. Type a choice and press **Enter**; Enter alone accepts
the displayed default. In option menus, **B** goes back and **Q** exits.

| Choose | Task |
| --- | --- |
| **1–10** | [Create playlists](#create-playlists) without changing file formats. |
| **C** | [Convert C64 NIB/NBZ to G64](#c64-converter-c). |
| **Z** | [Convert ZX Spectrum IPF to DSK](#zx-converter-z). |
| **S** | [Make supported playlists appear in Onion's game list](#sd-setup). |
| **D** | [Demo](#demo). |
| **F** | Switch the bunny and logo between CRT and Smooth. |
| **Q** | Exit. |

## Prepare a batch

Copy one system's games into `SRC`. They can be one ZIP per game, a folder per
game, or individual files. Finished files go into `DST`.

For a separate batch folder, create `SRC` and `DST` inside it, then drag the
folder onto `OptiMiyoo.bat`.

## Create playlists

For discs kept as individual files, use numbered names like these:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

Inside a game folder, `Disc 1.chd` and `Disc 2.chd` also work.
For tape sides, use `Game (Side A).tap` and `Game (Side B).tap`.

Keep CUE files, their tracks, and any matching SBI files together.
Keep different versions of the same disc in separate batches.

Choose your [system number](#systems-and-rom-folders), then how to save the files:

- **1: Auto** (default) keeps supported ZIPs intact for Amiga, C64, and VIC-20,
  and extracts them for other systems.
- **2: Folders** extracts ZIPs. Use this for games that write to disk images.

Then [choose what happens to originals](#originals-and-existing-files) to start.

For games with multiple discs or tape sides, the playlist stays visible and the
game files go into `.hidden`. Games with one disc or tape side stay visible
without a playlist.

## Convert disk images

Choose **C** or **Z**, then how to save the converted files:

- **1: Loose files**
- **2: ZIP files** (default)

Then [choose what happens to originals](#originals-and-existing-files) to start.
These options convert files only. To make playlists afterwards, [prepare a new
batch](#prepare-a-batch) using the converted files and choose a numbered system.

### C64 converter: C

Converts NIB/NBZ to G64 and copies existing G64 images unchanged.
Files from the same game ZIP stay together.

### ZX converter: Z

Converts each IPF to DSK separately.
Some IPF copy-protection details cannot be preserved in DSK.

## Originals and existing files

Choose **1: Keep originals** (default) or **2: Remove originals** to start a batch.
Remove deletes original files from `SRC` only after checking the finished files
in `DST`. Skipped or failed files are kept.

If a file or folder with the same name already exists in `DST`:

| Key | Action |
| --- | --- |
| **Y** | Overwrite the files shown |
| **N / Enter** | Skip this game or disc |
| **A** | Overwrite all matching files or folders in this batch |
| **S** | Skip all games or discs with existing files in this batch |

Use **> / <** to see more of the file list. **B / Q** also means Skip here.

## Copy to your Miyoo

After a batch, **Enter** returns to the main menu and **Q** exits.
Copy the wanted contents of `DST`, including `.hidden` when present, to the
system's ROM folder on your SD card, then refresh the game list.

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

Onion's standard emulators do not support playlists for **5, 8, or 10**.
**S** checks the emulators selected on your SD card; C64 tape-side support is shown
in its playlist menu.

### SD setup

Choose **S** and enter your SD drive, such as `E:\`. **Esc** cancels.
Setup makes supported playlists and C64 tape files appear in Onion's game list.
Your selected emulators, games, and saves stay as they are.

To undo setup, copy each saved `config.json` from `OptiMiyoo_Backup_<ID>` on the
SD card back to its matching emulator folder.

### Swap discs

To swap discs, launch the playlist and open **RetroArch → Quick Menu → Disk
Control**: eject, select the next image, and insert. C64 tapes may also need
keyboard/load commands; DOSBox Pure uses its own disk-selection controls.

## Demo

Choose **D**, then **1** for a full walkthrough of the menus, animations, and
main features. The demo does not change game or SD files.

During playback, keys work without Enter:

- **Space:** pause/resume. **Left / Right:** previous/next screen.
- **R:** restart the demo.
- **B / Q / Esc:** return to demo selection.
