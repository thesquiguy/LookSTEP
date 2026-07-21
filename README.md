# LookSTEP

LookSTEP previews STEP files in Finder on macOS. Select a `.step` or `.stp`
file and press Spacebar to inspect it.

![Raspberry Pi assembly shown in LookSTEP's Finder Quick Look preview](docs/images/lookstep-raspberry-pi-quick-look.jpg)

## Features

- Interactive Quick Look and Column View previews.
- Reads STEP face and part colors. When a file has no color data, separate
  parts receive distinct fallback colors.
- Adjusts tessellation by file size and part size to keep curved surfaces
  smooth without making previews unnecessarily heavy.
- Orbit and zoom with your mouse, just like in CAD. Shift-drag to pan, or use
  the Fit to Window button to reframe the model.
- Caches converted models for faster repeat previews.
- Limits import time and triangle count to protect Finder from difficult files.
- Processes files locally.

## Install

Requires an Apple Silicon Mac running macOS 15 or later, Xcode, and
[Homebrew](https://brew.sh/).

Download this repository, open Terminal in the source folder, and run:

```sh
bash install.sh
```

The installer builds LookSTEP and installs it in `/Applications`. To install it
in your personal Applications folder instead, run `bash install.sh --user`.
See [BUILDING.md](BUILDING.md) for manual installation and troubleshooting.

## Use

![Fitted side view of a Raspberry Pi assembly in LookSTEP](docs/images/lookstep-raspberry-pi-side-view.jpg)

1. Select a `.step` or `.stp` file in Finder.
2. Press Spacebar, or use Finder's Column View preview.
3. Left-drag to orbit, scroll or pinch to zoom, and Shift-left-drag to pan.

LookSTEP's small app is a diagnostic viewer. Finder Quick Look is the main
experience.

## How it works

[Open CASCADE Technology](https://dev.opencascade.org/) reads the STEP geometry
and colors, then converts the model into triangles. LookSTEP caches that mesh
and renders it with RealityKit inside Finder. Imports run in a separate service
with time and triangle limits.

LookSTEP is an early source release. Very large or unusual STEP files may be
slow or fail to preview.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Do not post
confidential CAD files in public issues.

## License

LookSTEP is available under the [MIT License](LICENSE). Third-party licenses are
listed in [THIRD_PARTY.md](THIRD_PARTY.md).
