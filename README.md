# OptiMiyoo

Create multi-disc playlists or convert C64 and ZX Spectrum disk images for
**Onion OS on Miyoo Mini Plus**.

[**Download for Windows**](https://github.com/OptiBunny/OptiMiyoo/archive/refs/heads/main.zip)
· [**User guide**](docs/USAGE.md)

![Animated OptiMiyoo terminal interface](assets/preview.gif)

## Quick start

**Windows 10 (1809+) / 11 · 64-bit (x64) · Windows PowerShell 5.1**

1. Download and extract the ZIP to a writable folder with a short path.
2. Copy one system's games into the app's `SRC` folder. See
   [how to prepare your games](docs/USAGE.md#prepare-a-batch).
3. Run **`OptiMiyoo.bat`**. Choose **C** for [C64 conversion](docs/USAGE.md#c64-converter-c),
   **Z** for [ZX Spectrum conversion](docs/USAGE.md#zx-converter-z), or a
   **numbered system** for [playlists](docs/USAGE.md#create-playlists).
4. Choose [how to save the files](docs/USAGE.md#choose-how-to-save), then what
   to do with the originals. Originals are kept by default.
5. Copy the finished files from `DST`, including `.hidden` when present, to the
   matching [Onion ROM folder](docs/USAGE.md#systems-and-rom-folders) on your
   SD card. Then [refresh Onion's game list](docs/USAGE.md#copy-to-your-miyoo) on the Miyoo.

If playlists or other supported file types are missing from Onion's game list,
connect the card to your PC and choose **S** for [SD setup](docs/USAGE.md#sd-setup).
Review the settings, turn the entries you need on, and choose **Apply**.

Choose **D** for a [demo](docs/USAGE.md#demo) showcasing the menus, animations,
and main features. The demo does not change game or SD files.

## Credits and disclosure

Converter tools are included; ROMs, BIOS files, and Onion cores are not.

AI disclosure: OptiMiyoo is almost entirely vibe-coded. Most of the project’s own code, tests, and documentation were generated and revised by AI. Use it at your own risk.

Bundled third-party tools have their own authors and licenses.

[NIBTools](https://github.com/rittwage/nibtools) ·
[HxC Floppy Emulator](https://github.com/jfdelnero/HxCFloppyEmulator) ·
[CAPSIMG](https://github.com/FrodeSolheim/capsimg) ·
[GCC / MinGW-w64 runtimes from MSYS2](https://github.com/msys2/MINGW-packages)

CAPSIMG's included license restricts commercial use.
See [third-party licenses and source details](third_party/README.md).
