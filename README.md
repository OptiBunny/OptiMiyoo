# OptiMiyoo

Prepare disk images and multi-disc playlists for **Onion OS on Miyoo Mini Plus**,
including C64 NIB/NBZ → G64 and ZX Spectrum IPF → DSK conversion.

[**Download ZIP for Windows**](https://github.com/OptiBunny/OptiMiyoo/archive/refs/heads/main.zip)
· [**User guide**](docs/USAGE.md)

![Animated OptiMiyoo terminal interface](assets/preview.gif)

## Quick start

**Windows 10 (1809+) / 11 x64 · Windows PowerShell 5.1**

1. Download and extract the ZIP to a writable folder.
2. Copy one system's game files into `SRC` as loose files, folders, or one ZIP per
   game. Keep each game's discs, tape sides, and companion files together.
3. Run **`OptiMiyoo.bat`**. Choose your system to create playlists, or select a
   converter to change disk-image formats, then follow the prompts.
4. Copy the resulting `DST` contents—including `.hidden` when present—to the matching
   [Onion ROM folder](docs/USAGE.md#systems-and-rom-folders), then refresh the game list.

Originals are kept by default. **D** previews the workflow without changing game files.
Converter tools are included; ROMs, BIOS files, and Onion cores are not.

AI disclosure: OptiMiyoo is almost entirely vibe-coded. Most of the project’s own code, tests, and documentation were generated and revised by AI. Use it at your own risk.

Bundled third-party tools have their own authors and licenses.

[NIBTools](https://github.com/rittwage/nibtools) ·
[HxC Floppy Emulator](https://github.com/jfdelnero/HxCFloppyEmulator) ·
[CAPSIMG](https://github.com/FrodeSolheim/capsimg) ·
[GCC / MinGW-w64 runtimes from MSYS2](https://github.com/msys2/MINGW-packages)

CAPSIMG's included license restricts commercial use.
See [third-party licenses and source details](third_party/README.md).
