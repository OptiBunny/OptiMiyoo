# Third-party components

These tools and libraries are included for conversion on Windows. Their original
licenses and notices are kept in the linked folders.

| Component | Used for | License and source details |
| --- | --- | --- |
| [NIBTools](https://github.com/rittwage/nibtools), release 20241120 | `nibconv.exe` converts C64 NIB/NBZ images to G64. | [Details](nibtools/SOURCE.txt) · [License](nibtools/LICENSE.txt) |
| [HxC Floppy Emulator](https://github.com/jfdelnero/HxCFloppyEmulator), 2.16.13.1 | Converts ZX Spectrum IPF images to DSK. | [Details](hxc/SOURCE.txt) · [Notices](hxc/COPYING_FULL) |
| [CAPSIMG](https://github.com/FrodeSolheim/capsimg), FS-UAE Windows builds | Reads IPF images: 5.1.3 for x64; 5.1fs3 for the x86 fallback. | [Details](capsimg/SOURCE.txt) · [License](capsimg/LICENSE.txt) |
| [GCC](https://gcc.gnu.org/) and [MinGW-w64](https://www.mingw-w64.org/) runtimes, packaged by [MSYS2](https://github.com/msys2/MINGW-packages) | Libraries required by the x86 CAPSIMG fallback. | [Details and licenses](runtime/SOURCE.txt) |

Both x64 and x86 converter builds are included. CAPSIMG's Windows DLLs match the
original FS-UAE downloads, with a versioned source archive for each build.

Device-side emulator libraries, such as Amiga `capsimg.so` for the Miyoo, are
separate and are not included.

These component licenses do not define a license for OptiMiyoo's own code.
