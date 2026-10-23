# Third-party components

OptiMiyoo bundles these tools and libraries unchanged. Their licenses, notices,
source information, and supplied source archives are kept here.

| Component | Used for | Notices and source information |
| --- | --- | --- |
| [NIBTools](https://github.com/rittwage/nibtools) | C64 NIB/NBZ conversion with `app/tools/nibconv.exe` | [nibtools](nibtools) |
| [HxC Floppy Emulator](https://github.com/jfdelnero/HxCFloppyEmulator) | ZX IPF conversion, with x64 and x86 engines in `app/ZX/tools/hxc` | [hxc](hxc) |
| [CAPSIMG](https://github.com/FrodeSolheim/capsimg) | IPF decoding by the ZX engines | [capsimg](capsimg) |
| [MSYS2 runtimes](https://packages.msys2.org/) | Local GCC and winpthread dependencies of the engines | [runtime](runtime) |

The GCC, GCC runtime exception, and winpthread license texts apply to both
architectures. Identical copies are stored once in `runtime`.

The supplied CAPSIMG source snapshot is reference material; it has not been
established as the exact source used to build the bundled 5.1fs3 binaries.
See [CAPSIMG provenance](capsimg/SOURCE.txt) for details.

These component licenses do not define a license for OptiMiyoo's own code.
