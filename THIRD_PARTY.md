# Third-Party Software

LookSTEP uses Open CASCADE Technology (OCCT) to read and tessellate STEP
files. Release builds bundle OCCT and the non-system libraries it links.
Apple frameworks are provided by macOS and are not included in this register.

## Open CASCADE Technology

| Field | Value |
| --- | --- |
| Version | 7.9.3 |
| Project | <https://dev.opencascade.org/> |
| Source | <https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_9_3.tar.gz> |
| Source SHA-256 | `5ecf094ec6b12d5413dfb851d8c3590c354058aee556e32e408bdfbf8c357d57` |
| License | GNU LGPL 2.1 with the Open CASCADE exception |
| Integration | Dynamically linked libraries bundled inside the import service |

The unmodified license and exception supplied with OCCT 7.9.3 are included
in [`ThirdPartyNotices`](ThirdPartyNotices). LookSTEP makes use of facilities
provided by the Open CASCADE Technology software.

Source builds use the Homebrew `opencascade` formula. The release build copies
only the dynamically linked OCCT library closure needed by the import service;
it does not vendor OCCT source in this repository.

## Runtime dependencies

| Dependency | Version | License | Source | Source SHA-256 |
| --- | --- | --- | --- | --- |
| FreeType | 2.14.3 | FreeType License | <https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz> | `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f` |
| libpng | 1.6.58 | libpng License 2.0 | <https://downloads.sourceforge.net/project/libpng/libpng16/1.6.58/libpng-1.6.58.tar.xz> | `28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775` |
| oneTBB | 2023.1.0 | Apache License 2.0 | <https://github.com/uxlfoundation/oneTBB/archive/refs/tags/v2023.1.0.tar.gz> | `191288b52e1e6b17198000b64d77d194bb65e791be46ebc606e9b091781e2070` |

The exact license files supplied with the Homebrew packages used for the
release are included in `ThirdPartyNotices`.

## Release verification

The dependency validator pins the installed OCCT, FreeType, libpng, and oneTBB
versions to this register before packaging. The Release verifiers then compare
every bundled notice and this register byte-for-byte
with the repository copies, reject stale or additional notice files, require
the dylib manifest to match the complete bundled `Frameworks` closure, and
reject library names outside these registered dependency families.
