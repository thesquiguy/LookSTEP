# LookSTEP

LookSTEP previews STEP files in Finder on macOS. Select a `.step` or `.stp`
file and press Spacebar to inspect it.

![Raspberry Pi assembly shown in LookSTEP's Finder Quick Look preview](docs/images/lookstep-raspberry-pi-quick-look.jpg)

## Features

- Interactive Quick Look and Column View previews.
- Reads STEP face and part colors. Geometry without color data uses one neutral
  light-gray fallback.
- Adjusts tessellation by file size and part size to keep curved surfaces
  smooth without making previews unnecessarily heavy.
- Orbit and zoom with your mouse, just like in CAD. Shift-drag to pan, or use
  the Fit to Window button to reframe the model.
- Caches converted models for faster repeat previews.
- Limits import time and triangle count to protect Finder from difficult files.
- Processes files locally.

## Install

LookSTEP requires an Apple Silicon Mac running macOS 26 or later.

LookSTEP is not yet notarized by Apple, because notarization requires a paid
Apple Developer account. That does not affect how the app runs, but it does
change how you get past macOS Gatekeeper. Pick whichever tradeoff you prefer.

### Option 1: Download the app

Fastest path. No Xcode, no Homebrew, no Open CASCADE install — the app carries
its own copy of every library it needs.

1. Download `LookSTEP-macos-arm64.zip` from the
   [latest release](https://github.com/thesquiguy/LookSTEP/releases/latest)
   and open it.
2. Drag `LookSTEP.app` to your `Applications` folder.
3. macOS will refuse to open it, because the app is not notarized. Open
   Terminal and run this once to clear the download quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/LookSTEP.app
   ```

4. Open LookSTEP once so Finder registers its preview extension.

Step 3 is the part worth understanding before you run it. macOS tags every
downloaded file with a quarantine flag, and Gatekeeper refuses to launch
quarantined apps that Apple has not notarized. That command removes the flag
from LookSTEP only. It does not disable Gatekeeper, and it does not affect any
other app. If you would rather not run it, use Option 2 instead — and if you
would rather not take an unsigned binary from a stranger on the internet at
all, that is a reasonable position, so use Option 2.

### Option 2: Build it yourself

Slower to set up, but nothing to bypass: an app you compile on your own Mac is
never quarantined, so it opens with no warnings. Requires
[Xcode](https://developer.apple.com/xcode/) and [Homebrew](https://brew.sh/).

1. [Download the source](https://github.com/thesquiguy/LookSTEP/archive/refs/heads/main.zip)
   and open the ZIP file.
2. Open Terminal and type `cd `, including the space. Drag the unzipped
   `LookSTEP-main` folder into the Terminal window, then press Return.
3. Run:

   ```sh
   bash install.sh
   ```

The installer checks your setup, builds LookSTEP, verifies it, and installs it
in `/Applications`. To install it in your personal Applications folder instead,
run `bash install.sh --user`. See [BUILDING.md](BUILDING.md) for manual
installation and troubleshooting.

Xcode is a large download, and LookSTEP genuinely needs all of it: the Command
Line Tools package alone does not include `xcodebuild`.

## Use

![Fitted side view of a Raspberry Pi assembly in LookSTEP](docs/images/lookstep-raspberry-pi-side-view.jpg)

1. Select a `.step` or `.stp` file in Finder.
2. Press Spacebar, or use Finder's Column View preview.
3. Left-drag to orbit, scroll or pinch to zoom, and Shift-left-drag to pan.
4. Use **LookSTEP → Settings** to keep the preview background white—the
   default—or let it follow your Mac’s Light or Dark appearance.

LookSTEP's small app is a diagnostic viewer. Finder Quick Look is the main
experience.

## How it works

[Open CASCADE Technology](https://dev.opencascade.org/) reads the STEP geometry
and colors, then converts the model into triangles. LookSTEP caches that mesh
and renders it with RealityKit inside Finder. Imports run in a separate service
with time and triangle limits.

LookSTEP is an early source release. Very large or unusual STEP files may be
slow or fail to preview.

## Measured preview times

Measured with OCCT 7.9.3 on an M1 MacBook Air with 8 GB of memory, running
macOS 26.4.1. Times run from Quick Look invoking LookSTEP's preview extension
to the first Metal-presented geometry frame. Each uncached trial uses a new
path and inode and must report an import; cached trials reopen the same path,
restart the preview processes, and must not invoke the importer.

| Anonymous model | Size | Definitions / instances | Triangles | Uncached median | Cached median | Preview / importer peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small nested assembly | 0.09 MB | 4 / 12 | 15,688 | 0.66 s | 0.13 s | 78 / 34 MiB |
| Medium colored model | 35.5 MB | 1 / 1 | 54,966 (4 faces missing) | 5.45 s, simplified | 0.13 s | 95 / 1,080 MiB |
| Large stress assembly | 61.8 MB | 147 / 261 | 252,541 (7 faces missing) | 11.30 s, simplified | 0.95 s | 129 / 652 MiB |
| High-complexity large source | 174.8 MB | — | — | Actionable refusal in 1.16 s | — | — |

Values are medians of three trials. File size alone does not predict STEP
complexity. LookSTEP deliberately simplifies expensive Finder previews and
refuses a cold import predicted to exceed its bounded preview window; the
source file is never modified.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Do not post
confidential CAD files in public issues.

## License

LookSTEP is available under the [MIT License](LICENSE). Third-party licenses are
listed in [THIRD_PARTY.md](THIRD_PARTY.md).
