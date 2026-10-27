# OptiMiyoo user guide

## Menu guide

Open **`OptiMiyoo.bat`**. Type a number or letter, then press **Enter**.
Press **Enter** on its own to use the default.

In submenus, **B** goes back and **Q** exits. In SD setup (**S**), use **Esc**
to go back.

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

Copy one system's games into the app's `SRC` folder, using ZIPs, a folder per game,
or individual files. Each ZIP is treated as one game, so include all its discs or tape sides.
Finished files go into `DST`.

To work in a separate folder, create `SRC` and `DST` inside it, then drag that
folder onto `OptiMiyoo.bat`.

## Create playlists

Give separate discs matching names with a disc number so OptiMiyoo can group them:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

Inside a game folder, `Disc 1.chd` and `Disc 2.chd` also work.
For C64 tape sides, use `Game (Side A).tap` and `Game (Side B).tap`.

Keep CUE files, their tracks, and any matching SBI files together. A CUE file
and its tracks count as one disc. Keep different editions of the same game in
separate batches.

Choose your [system number](#systems-and-rom-folders), then
[how to save the files](#choose-how-to-save).

A game with multiple discs or tape sides gets one playlist. Its game files go
in `DST/.hidden`, and the playlist stays outside that folder so it appears in
Onion's game list. Games with one disc or tape side stay visible without a playlist.

## Convert disk images

Choose **C** or **Z**, then [how to save the converted files](#choose-how-to-save).
These options convert files without creating playlists.

### C64 converter: C

Converts NIB/NBZ to G64.

### ZX converter: Z

Converts IPF to DSK. Some IPF copy-protection details cannot be preserved in DSK.

### Make playlists after conversion

After conversion, create a [separate batch folder](#prepare-a-batch) with
empty `SRC` and `DST` folders. Copy the contents of the first batch's `DST`
into the new `SRC`, then drag the new batch folder onto `OptiMiyoo.bat`.
Choose **2** for C64 or **9** for ZX Spectrum.

## Choose how to save

Numbered systems have two storage menus:

1. **Single games:** how to save games with one disc or tape side, which stay visible.
2. **Playlist media:** how to store multi-disc or multi-side game files in `.hidden`.

Both menus offer:

| Choice | How the game files are saved |
| --- | --- |
| **1: Auto** | Keep ZIPs zipped and keep the same folder layout for other files. |
| **2: ZIPs** | One ZIP per game. |
| **3: Folders** | One folder per game. |
| **4: Loose files** | Individual files, without adding a game folder. |

**C** and **Z** ask once, for converted files, using the same four choices.
**2: ZIPs** is the default. Auto keeps the input layout while converting the files.

After choosing storage, [choose what happens to the originals](#originals-and-existing-files)
to start processing.

## Originals and existing files

Choose **1: Keep originals** (default) to leave the files in `SRC`.
**2: Remove originals** deletes processed files from `SRC` after checking the
finished files in `DST`. Skipped or failed files are kept.

If a file or folder with the same name already exists in `DST`:

| Key | Action |
| --- | --- |
| **Y** | Overwrite the files shown |
| **N / Enter** | Keep the existing files and skip this game |
| **A** | Overwrite this and all later matches in the batch |
| **S** | Skip this and all later matches in the batch |

Use **> / <** to see more of the file list. Here, **B / Q** also skips the game.

When processing finishes, review the results. At that prompt, **Enter** returns
to the main menu and **Q** exits.

## Copy to your Miyoo

Copy the contents of `DST`, including `.hidden` when present, to the system's
ROM folder on your SD card. For playlists, use [SD setup](#sd-setup) to enable
supported file types in Onion's game list.

On the Miyoo, open **Games**, press **SELECT**, and choose
[**Refresh all roms**](https://onionui.github.io/docs/faq#i-have-added-new-roms-to-my-sd-card-why-are-the-games-not-showing-up).

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

Connect your SD card to the PC, choose **S**, and enter its drive, such as `E:\`.
This enables supported playlists, C64 tape files, and Atari Lynx `.lyx` files
in Onion's game list by updating its file-type settings. It does not install
or switch emulator cores. **Esc** goes back.

To undo setup, copy each saved `config.json` from `OptiMiyoo_Backup_<ID>` on the
SD card to its matching folder under `Emu`.

### Swap discs

Launch the playlist. When the game asks for another disc, open
**RetroArch → Quick Menu → [Disc Control](https://docs.libretro.com/guides/disc-swapping/)**.
Eject the current disc, select the next image, and insert it.
C64 tapes may also need keyboard/load commands.

## Demo

Choose **D**, then **1** for a walkthrough of the menus, animations, and main
features. The demo does not change game or SD files.

During playback, keys work without Enter:

- **Space:** pause/resume. **Left / Right:** previous/next screen.
- **R:** restart the demo.
- **E:** turn the CRT effect on or off.
- **B / Q / Esc:** return to demo selection.
