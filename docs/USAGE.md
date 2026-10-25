# OptiMiyoo user guide

## Menu guide

Run **`OptiMiyoo.bat`**. Type a choice and press **Enter**; Enter alone accepts
the displayed default. In option menus, **B** goes back and **Q** exits.

| Choose | Task |
| --- | --- |
| **1–10** | [Create playlists](#create-playlists) without changing file formats. |
| **C** | [Convert C64 NIB/NBZ to G64](#c64-converter-c). |
| **Z** | [Convert ZX Spectrum IPF to DSK](#zx-converter-z). |
| **S** | [Set up playlist visibility](#sd-setup-and-disc-swapping) on an Onion SD card. |
| **D** | [Demo](#demo). |
| **F** | Switch the bunny and logo between CRT and Smooth. |
| **Q** | Exit. |

## Prepare a batch

Copy one system's game files into `SRC`; finished files go into `DST`.
Files can be in subfolders.

- **[Playlists (1–10)](#create-playlists):** group each game's discs or tape sides
  using the naming examples below.
- **[Conversion (C or Z)](#convert-disk-images):** use NIB/NBZ for C64 or IPF for ZX,
  as individual files or in ZIPs. Disc and side labels are not required.

For a separate batch folder, create `SRC` and `DST` inside it, then drag the
folder onto `OptiMiyoo.bat`.

## Create playlists

Keep each game's discs or tape sides together, either as individual files or in
one ZIP. Give individual files matching game names and disc numbers, even inside
folders:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

For tape sides, use `Game (Side A).tap` and `Game (Side B).tap`.

Keep CUE files with their referenced tracks and matching SBI files.
Keep alternate releases or formats of the same disc in separate batches.

Choose your [system number](#systems-and-rom-folders), then storage:

- **1: Auto** (default) keeps supported ZIPs intact for Amiga, C64, and VIC-20,
  and extracts them for other systems.
- **2: Folders** extracts ZIPs. Use this for games that write to disk images.

Then [choose what happens to originals](#originals-and-existing-outputs) to start.

For games with multiple discs or tape sides, the playlist stays visible and the
game files go into `.hidden`. Games with one disc or tape side stay visible
without a playlist.

## Convert disk images

Choose **C** or **Z**, then the output format:

- **1: Loose files**
- **2: ZIP files** (default)

Then [choose what happens to originals](#originals-and-existing-outputs) to start.
Conversion does not create playlists; use a numbered system in a separate batch
if you also need one.

### C64 converter: C

Converts NIB/NBZ to G64 and copies existing G64 images unchanged.
Images and companion files from the same game ZIP stay together.

### ZX converter: Z

Converts each IPF to DSK separately.
Some IPF copy-protection details cannot be preserved in DSK.

## Originals and existing outputs

Choose **1: Keep originals** (default) or **2: Remove originals** to start a batch.
Remove deletes original files from `SRC` only after checking the finished files
in `DST`. Skipped or failed files are kept.

When an output already exists:

| Key | Action |
| --- | --- |
| **Y** | Overwrite this output |
| **N / Enter** | Skip this output |
| **A** | Overwrite all conflicts in the batch |
| **S** | Skip all conflicts in the batch |

The choice applies to the listed outputs. **> / <** pages through paths;
**B / Q** also means Skip at this prompt.

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

Standard Onion cores do not support playlists for **5, 8, or 10**.
**S** checks your SD card's selected cores; C64 tape-side support is shown
in its playlist menu.

### SD setup and disc swapping

Choose **S** and enter your SD drive, such as `E:\`. **Esc** cancels.
Setup adds supported playlist extensions without changing selected cores,
games, or saves. To undo it, restore `config.json` from the corresponding
`OptiMiyoo_Backup_<ID>` folder to its original emulator folder.

To swap discs, launch the playlist and open **RetroArch → Quick Menu → Disk
Control**: eject, select the next image, and insert. C64 tapes may also need
keyboard/load commands; DOSBox Pure uses its own disk-selection controls.

## Demo

Choose **D**, then **1** for the full walkthrough. The demo showcases menus,
animations, and workflows without changing game or SD files.

During playback, keys work without Enter:

- **Space:** pause/resume. **Left / Right:** previous/next screen.
- **R:** restart the section.
- **B / Q / Esc:** return to demo selection.
