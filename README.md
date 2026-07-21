# LookSTEP

LookSTEP adds fast, interactive STEP previews to Finder on macOS. Select a
`.step` or `.stp` file and press Spacebar to inspect it without launching a CAD
application.

It is built for one job: checking a model quickly. The preview uses a clean
white background, CAD-style navigation, STEP colors, assembly structure, and a
single Fit control for quick screenshots.

## Features

- Interactive Finder Quick Look previews and large Column View previews.
- STEP face colors, part colors, assembly transforms, and repeated instances.
- Deterministic Onshape-inspired colors for separate parts when a file has no
  useful color information.
- Adaptive tessellation that balances curved-surface quality against preview
  time and triangle count.
- Pointer-centered orbit and zoom, plus a tight fit-to-window control.
- A versioned local mesh cache for faster repeat previews.
- Bounded import time and triangle counts so difficult files fail cleanly
  instead of taking down Finder's preview.
- Local processing only. LookSTEP does not upload CAD files or require an
  account.

Finder continues to use the icon from your chosen default STEP application.
LookSTEP supplies the large preview, not the document icon.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Xcode
- [Homebrew](https://brew.sh/)

LookSTEP is distributed as source. Building it locally is the supported
installation method and does not require a paid Apple Developer account.

## Install

1. Install Xcode from Apple and open it once so it can finish installing its
   components. Install Homebrew if it is not already available.
2. Download and expand this repository's source ZIP, or clone the repository.
3. In Terminal, run the installer from the source folder:

   ```sh
   bash install.sh
   ```

The installer checks the Mac and required tools, offers to install Open CASCADE
Technology through Homebrew when needed, builds an ad-hoc-signed Release app,
verifies it, and installs it in `/Applications`. An existing LookSTEP app is
moved to Trash first so upgrades remain recoverable. The installed app embeds
the OCCT runtime libraries it needs and is self-contained.

If `/Applications` is not writable for your account, install in your personal
Applications folder instead:

```sh
bash install.sh --user
```

Run `bash install.sh --help` for all options. See
[BUILDING.md](BUILDING.md) for manual Xcode instructions, testing, removal, and
troubleshooting.

## Use it

1. Select a `.step` or `.stp` file in Finder.
2. Press Spacebar, or show Finder's preview pane in Column View.
3. Navigate the model:

   | Input | Action |
   | --- | --- |
   | Left-drag | Orbit around the point under the pointer |
   | Scroll or pinch | Zoom toward the pointer |
   | Shift-left-drag | Pan |
   | Fit button | Recenter and tightly frame the model |

The small LookSTEP app is mainly a diagnostic host. Finder Quick Look is the
primary experience.

## How it works

```text
STEP file
  -> Finder Quick Look extension
  -> versioned local cache lookup
  -> isolated OCCT import service
  -> XCAF assembly and color traversal
  -> adaptive tessellation
  -> compact mesh archive
  -> RealityKit preview
```

[Open CASCADE Technology](https://dev.opencascade.org/) reads the STEP/XCAF
document, preserves part definitions and assembly occurrences, and converts
the model's faces into renderable triangles. Unique part definitions are
meshed once and reused by each occurrence instead of flattening the assembly.

The importer runs in a separate XPC service with a time limit and a triangle
budget. If a file is malformed, unsupported, or too expensive for a quick
preview, LookSTEP can stop the importer and show a useful failure instead of
leaving an empty Quick Look window or crashing the preview. Successful imports
are stored in a versioned cache and automatically rebuilt when the source file
or tessellation profile changes.

[RealityKit](https://developer.apple.com/augmented-reality/realitykit/) renders
the cached mesh with a light CAD-style appearance. Camera math keeps orbit and
zoom anchored to the pointer, which makes navigation feel closer to a CAD
viewport than a generic model viewer.

## Current status

LookSTEP is an early source release intended for hands-on feedback. Core
previewing, navigation, colors, caching, adaptive tessellation, and bounded
failure handling are working. STEP is a broad exchange format, so unusual or
very large files may still import slowly, omit unsupported geometry, or fail.

When reporting a geometry problem, include a redistributable sample or a small
non-confidential reproduction whenever possible. Do not upload confidential
CAD files to a public issue.

## Contributing

Focused improvements to STEP import, Finder preview behavior, rendering,
caching, and failure handling are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
before submitting a change.

## License and dependencies

LookSTEP is available under the [MIT License](LICENSE).

LookSTEP uses Open CASCADE Technology under LGPL 2.1 with the OCCT exception.
Release builds also bundle its FreeType, libpng, and oneTBB runtime
dependencies. Versions, source archives, checksums, and required notices are
recorded in [THIRD_PARTY.md](THIRD_PARTY.md) and `ThirdPartyNotices/`.
