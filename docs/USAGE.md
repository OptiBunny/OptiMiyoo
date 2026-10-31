# OptiMiyoo user guide

## Menu guide

Open **`OptiMiyoo.bat`**. Type a number or letter, then press **Enter**.
Press **Enter** on its own to use the default shown at the prompt.

In selection menus, **B** goes back and **Q** exits. While choosing SD settings
(**S**), use **Esc** to go back without saving. Demo playback and overwrite
prompts have their own controls below.

To create playlists or convert files, [prepare your games](#prepare-a-batch) first.

| Choose | Task |
| --- | --- |
| **S** | [Choose file types in Onion's game list](#sd-setup). |
| **C** | [C64 converter](#c64-converter-c). |
| **Z** | [ZX Spectrum converter](#zx-converter-z). |
| **1–9** | [Create playlists](#create-playlists) without converting disk images. |
| **D** | [Demo](#demo). |
| **E** | [Turn the CRT effect on or off](#crt-effect). |
| **Q** | [Exit](#exit). |

## SD setup

Use **S** to enable or disable playlists, C64 tape files, and Atari Lynx `.lyx`
files in Onion's game list.

Connect the card to your PC, choose **S**, and enter its drive or main folder,
such as `E:\`. OptiMiyoo reads the existing `Emu` config files and shows which
of the listed file types are **On**, **Off**, or **Partly enabled**. A system is
**Unavailable** if its config is missing, unreadable, or invalid.

- Type **1**, then **Enter**, to turn all available systems on, or off if they are
  already all on.
- Type a system's number, then **Enter**, to toggle that system.
- Choose **A / Enter** to **Apply**, or **Esc** to leave without saving.

**On** adds the listed file types; **Off** removes them from the game list.
Other file types and the game files themselves stay unchanged. Setup does not
check, install, or switch emulator cores. The menu's support notes explain which
cores can use the enabled files.

After Apply, the results show what was enabled or disabled. **Already on/off**
means no change was needed. A partly enabled system stays as it was unless you
toggle it. **Enter / Esc** returns to the main menu; **Q** exits.
[Refresh Onion's game list](#copy-to-your-miyoo) after making changes.

Changed configs are backed up on the card before they are replaced, in a dated
folder such as `Backups/OptiMiyoo_2026-10-31-10-30-00/Emu`.

To restore a setting, use a **verified backup** listed in the results: copy its
`config.json` into the matching system folder under the card's `Emu` folder.
PlayStation's config folder is `Emu/PSX`; its games still go in `Roms/PS`.

## Convert disk images

After [preparing a batch](#prepare-a-batch), choose **C** or **Z**, then
[how to save the converted files](#choose-how-to-save).
These options convert files without creating playlists.

### C64 converter: C

Converts NIB/NBZ to G64. Existing G64 images are copied without conversion.

### ZX converter: Z

Converts IPF to DSK. Existing DSK images are copied without conversion.
Some IPF copy-protection details cannot be preserved in DSK.

### Make playlists after conversion

1. Create a [separate batch folder](#prepare-a-batch) with empty `SRC` and `DST` folders.
2. Copy the contents of the first batch's `DST` into the new `SRC`.
3. Drag the new batch folder onto `OptiMiyoo.bat`. Choose **2** for C64.
   For ZX Spectrum, choose **9** only if your installed core supports playlists;
   Onion's default Fuse build does not.

## Create playlists

[Prepare a batch](#prepare-a-batch) for one system. Give separate discs matching
names with a disc number so OptiMiyoo can group them:

```text
Game (Disc 1).chd
Game (Disc 2).chd
```

Inside a folder named after the game, `Disc 1.chd` and `Disc 2.chd` also work,
as do names such as `(Disc 1).chd` and `(Disc 2).chd`.
For C64 tape sides, use `Game (Side A).tap` and `Game (Side B).tap`.

Keep CUE files, their tracks, and any matching SBI files together. A CUE file
and its tracks count as one disc. Keep different editions of the same game in
separate batches.

Choose your [system number](#systems-and-rom-folders), then
[how to save the files](#choose-how-to-save). Numbered options keep the game
files in their original formats; use **C** or **Z** separately for conversion.

A game with multiple discs or tape sides gets one playlist. Its game files go
in `DST/.hidden`, and the playlist stays outside that folder so it appears in
Onion's game list. Games with one disc or tape side stay visible without a playlist.

### Systems and ROM folders

| # | System | Onion folder |
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

The default Onion cores for **8: Amstrad CPC** (CrocoDS) and **9: ZX Spectrum**
(Fuse) cannot load playlists. OptiMiyoo can create the files, but playback needs
a compatible core. [SD setup](#sd-setup) does not add playlist support to a core.
ZX conversion remains available through **Z**.

## Prepare a batch

Copy one system's games into the app's `SRC` folder, using ZIPs, a folder per game,
or individual files. Each ZIP is treated as one game, so include all its discs or tape sides.
Finished files go into `DST`.

To work in a separate folder, create `SRC` and `DST` inside it, then drag that
folder onto `OptiMiyoo.bat`.

## Choose how to save

C and Z ask once for the converted files. Numbered systems ask separately for:

1. **Single games:** how to save games with one disc or tape side, which stay visible.
2. **Playlist media:** how to store multi-disc or multi-side game files in `.hidden`.

The storage choices are:

| Choice | How the game files are saved |
| --- | --- |
| **1: Auto** | Keep ZIPs zipped and keep the same folder layout for other files. |
| **2: ZIPs** | One ZIP per game. |
| **3: Folders** | One folder per game. |
| **4: Loose files** | Individual files, without adding a game folder. |

The default depends on the system and the menu:

| Menu | Default |
| --- | --- |
| **Single games** | **4: Loose files** for PlayStation, Sega CD and Amstrad CPC; **2: ZIPs** for the others. |
| **Playlist media** | **2: ZIPs** for Amiga, C64 and VIC-20; **3: Folders** for the others. |
| **C / Z converted files** | **2: ZIPs**. |

For playlist media, **Auto** preserves the input layout inside `.hidden`.
The playlist file itself always stays outside `.hidden`, whichever storage
choice you make.

Playlists can point inside ZIPs with the standard Amiga, C64 and VIC-20 cores.
For the other systems, choose **Folders** or **Loose files** and check that
your core supports playlists. Follow the support notes shown beside ZIP choices.
For conversion, **Auto** keeps the input layout while converting the files.

After choosing storage, [choose what happens to the originals](#originals-and-existing-files)
to start processing.

## Originals and existing files

Choose **1: Keep originals** (default) to leave the files in `SRC`.
**2: Remove originals** deletes processed files from `SRC` after checking the
finished files in `DST`. Skipped or failed files are kept, as are files still
needed by a playlist that remains in `SRC`.

If a file or folder with the same name already exists in `DST`:

| Key | Action |
| --- | --- |
| **Y** | Overwrite the output shown |
| **N / Enter** | Keep the existing files and skip this output |
| **A** | Overwrite this and all later matches in the batch |
| **S** | Skip this and all later matches in the batch |

Overwriting a folder replaces all of its contents.
Use **> / <** to see more of the file list. Here, **B / Q** also skips this output.

### Results and stopping a batch

When processing finishes, review the saved, skipped, and failed outputs, along
with the counts of originals removed or kept. The CSV report and log are saved
beside `SRC` and `DST`; their paths appear in the results. **Enter** returns to
the main menu and **Q** exits.

Press **Ctrl+C** during processing to request a stop. The current operation may
finish before the app closes. Stopping does not undo completed work: saved
outputs stay saved, and originals already removed are not restored.

## Copy to your Miyoo

Copy the contents of `DST`, including `.hidden` when present, to the system's
[ROM folder](#systems-and-rom-folders) on your SD card. For playlists, use
[SD setup](#sd-setup) if you have not already enabled the supported file types.

On the Miyoo, open **Games**, press **SELECT**, and choose
[**Refresh all roms**](https://onionui.github.io/docs/faq#i-have-added-new-roms-to-my-sd-card-why-are-the-games-not-showing-up).

### Swap discs

With a core that supports playlists, launch the playlist. When the game asks for
another disc, open
**RetroArch → Quick Menu → [Disc Control](https://docs.libretro.com/guides/disc-swapping/)**.
Eject the current disc, select the next image, and insert it.
C64 tapes may also need keyboard/load commands. DOSBox Pure also provides
[image selection in its start menu](https://docs.libretro.com/library/dosbox_pure/#mount-disc-images-from-inside-zip-files).

## Demo

Choose **D**, then **1** for a walkthrough of the menus, animations, and main
features. To see one topic, choose **2** for C64, **3** for ZX, **4** for playlists,
**5** for results and overwrite choices, **6** for the bunny animations, or
**7** for core support and SD setup. All progress and results are examples;
the demo does not change game or SD files.

During playback, keys work without Enter:

- **Space:** pause/resume.
- **Left / P:** previous screen. **Right / N / Enter:** next screen.
- **R:** restart the selected demo section.
- **E:** turn the CRT effect on or off.
- **B / Q / Esc:** return to demo selection.

## CRT effect

At the main menu, choose **E** to turn the CRT effect on or off.

To turn off decorative animations as well, start the app from a terminal in its
folder with `.\OptiMiyoo.bat -NoAnimation`.

## Exit

At the main menu, choose **Q** to exit.
