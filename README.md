# OptiMiyoo

Prepare disk images and multi-disc playlists for **Onion OS on Miyoo Mini Plus**,
including C64 NIB/NBZ → G64 and ZX Spectrum IPF → DSK conversion.

[**Download ZIP for Windows**](https://github.com/OptiBunny/OptiMiyoo/archive/refs/heads/main.zip)
· [**User guide**](docs/USAGE.md)

![Animated OptiMiyoo terminal interface](assets/preview.gif)

## Quick start

**Windows 10 (1809+) / 11 x64 · Windows PowerShell 5.1**

1. Download and extract the ZIP to a writable folder.
2. Put one system's games in `SRC`, then run **`OptiMiyoo.bat`**.
3. Choose a numbered system for playlists in the original formats (**2** for C64),
   **C** to convert C64 NIB/NBZ game ZIPs to G64, or **Z** to convert ZX IPF to DSK.
4. Copy the resulting `DST` contents—including `.hidden` when present—to the matching
   [Onion ROM folder](docs/USAGE.md#systems-and-rom-folders), then refresh the game list.

Use **C** or **Z** only when you want conversion; numbered playlist modes keep
the original formats. [Using converted media in playlists](docs/USAGE.md#playlists-after-conversion).

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
