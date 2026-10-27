# OptiMiyoo user guide

## Menu guide

Open **`OptiMiyoo.bat`**. Type an option's number or letter and press **Enter**.
Press **Enter** without typing anything to choose the default. Each menu shows
how to go back or exit.

| Choose | Task |
| --- | --- |
| **S** | [Enable supported file types in Onion's game list](#sd-setup). |
| **C** | [C64 converter](#c64-converter-c). |
| **Z** | [ZX Spectrum converter](#zx-converter-z). |
| **1–9** | [Create playlists](#create-playlists) without changing file formats. |
| **D** | [Demo](#demo). |
| **E** | Turn the CRT effect on or off. |
| **Q** | Exit. |

## Prepare a batch

Copy one system's games into `SRC`, using one ZIP per game, a folder per game,
or individual files. Finished files go into `DST`.

To work in a separate folder, create `SRC` and `DST` inside it, then drag that
folder onto `OptiMiyoo.bat`.

## Create playlists

Choose your [system number](#systems-and-rom-folders). Give separate discs
matching names with a disc number so OptiMiyoo can group them:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

Inside a game folder, `Disc 1.chd` and `Disc 2.chd` also work.
For tape sides, use `Game (Side A).tap` and `Game (Side B).tap`.

Keep CUE files, their tracks, and any matching SBI files together. Keep different
versions of the same disc in separate batches.

For games with multiple discs or tape sides, the ZIP, game folder or loose files
go in `.hidden`. The playlist stays outside it, visible in Onion's game list.
Games with one disc or tape side stay visible without a playlist.

## Convert disk images

**C** and **Z** convert files without creating playlists. To make playlists
afterwards, use the converted files as input for a [new batch](#prepare-a-batch)
and choose a numbered system.

### C64 converter: C

Converts NIB/NBZ to G64.

### ZX converter: Z

Converts IPF to DSK. Some IPF copy-protection details cannot be preserved in DSK.

## Choose how to save

Numbered systems ask separately how to save single games and how to store
the game files used by playlists in `.hidden`. C and Z ask once, for converted files.

| Format | Numbered systems | C / Z | Result |
| --- | --- | --- | --- |
| **Auto** | **1** | — | Keep the input layout. |
| **ZIPs** | **2** | **1** | One ZIP per game. |
| **Folders** | **3** | **2** | One folder per game. |
| **Loose files** | **4** | **3** | Files without adding a game folder. |

Playlists themselves always stay outside `.hidden`.

## Originals and existing files

Choose **1: Keep originals** (default) or **2: Remove originals** to start.
Remove deletes processed files from `SRC` only after checking the finished files
in `DST`. Skipped or failed files are kept.

If a file or folder with the same name already exists in `DST`:

| Key | Action |
| --- | --- |
| **Y** | Overwrite the files shown |
| **N / Enter** | Keep them and skip this game or disc |
| **A** | Overwrite this and all later matches in the batch |
| **S** | Skip this and all later matches in the batch |

Use **> / <** to see more of the file list. **B / Q** also means Skip here.

## Copy to your Miyoo

Copy the contents of `DST`, including `.hidden` when present, to the system's
ROM folder on your SD card. Then refresh Onion's game list.

### Systems and ROM folders

| Menu | System | Onion folder |
| --- | --- | --- |
| **1** | Amiga | `Roms/AMIGA` |
| **2** | Commodore 64 | `Roms/COMMODORE` |
| **3** | MS-DOS | `Roms/DOS` |
| **4** | MSX / MSX2 | `Roms/MSX` |
| **5** | PlayStation | `Roms/PS` |
| **6** | Sega CD / Mega-CD | `Roms/SEGACD` |
| **7** | VIC-20 | `Roms/VIC20` |
| **8** | Amstrad CPC | `Roms/CPC` |
| **9** | ZX Spectrum | `Roms/ZXS` |

### SD setup

Choose **S** and enter your SD drive, such as `E:\`. This enables supported
playlists, C64 tape files, and Atari Lynx `.lyx` files in Onion's game list.
It does not install or switch emulator cores. **Esc** goes back.

To undo setup, copy each saved `config.json` from `OptiMiyoo_Backup_<ID>` on the
SD card to its matching folder under `Emu`.

### Swap discs

Launch the playlist, then open **RetroArch → Quick Menu → Disk Control**.
Eject the current disc, select the next image, and insert it. C64 tapes may also
need keyboard/load commands; DOSBox Pure has its own disc-selection controls.

## Demo

Choose **D**, then **1** for a walkthrough of the menus, animations, and main
features. The demo does not change game or SD files.

During playback, keys work without Enter:

- **Space:** pause/resume. **Left / Right:** previous/next screen.
- **R:** restart the demo.
- **B / Q / Esc:** return to demo selection.
