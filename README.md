# OptiMiyoo

Prepare disk images and multi-disc playlists for **Onion OS on Miyoo Mini Plus**,
including C64 NIB/NBZ → G64 and ZX Spectrum IPF → DSK conversion.

[**Download for Windows**](https://github.com/OptiBunny/OptiMiyoo/releases/latest)
· [**Menu guide**](docs/USAGE.md#menu-guide)

![Animated OptiMiyoo terminal interface](assets/preview.gif)

## Quick start

**Windows 10 (1809+) / 11 x64 · Windows PowerShell 5.1 · Converter tools included**

1. Download the Windows ZIP from the release assets and extract it to a writable folder.
2. Put one system's games in `SRC`, then run **`OptiMiyoo.bat`**.
3. Choose a numbered system for playlists, **C** for C64 conversion, or **Z** for ZX.
4. Review the results, copy `DST` contents—including `.hidden`—to the matching
   [Onion ROM folder](docs/USAGE.md#systems-and-rom-folders), and refresh the game list.

Originals are kept by default. **D** runs a demo without changing game files.
ROMs, BIOS files, and Onion cores are not included.

The current source code adds Windows process isolation around the normal app
window, with a trusted host for approved file changes. This is **not yet included
in the published 1.0.0 download**. See [processing isolation](docs/USAGE.md#processing-isolation)
for its requirements and temporary disk-space needs.

**1.0.0 — Initial public release**

**AI disclosure:** OptiMiyoo is almost entirely vibe-coded. Most of the project’s own code, tests, and documentation were generated and revised by AI. Use it at your own risk.

Bundled third-party tools have their own authors and licenses:
[NIBTools](https://github.com/rittwage/nibtools),
[HxC Floppy Emulator](https://github.com/jfdelnero/HxCFloppyEmulator),
[CAPSIMG (FS-UAE Windows build)](https://github.com/FrodeSolheim/capsimg), and
GCC / MinGW-w64 runtimes packaged by [MSYS2](https://github.com/msys2/MINGW-packages).

CAPSIMG's included license restricts commercial use.
See [third-party licenses and source details](third_party/README.md).
