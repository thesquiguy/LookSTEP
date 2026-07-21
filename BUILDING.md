# Build LookSTEP from source

LookSTEP supports Apple Silicon Macs running macOS 15 or later. A local build
does not require a paid Apple Developer account or a Developer ID certificate.

## Quick installation

Install Xcode and [Homebrew](https://brew.sh/), open Xcode once to finish its
setup, then run this from the LookSTEP source folder:

```sh
bash install.sh
```

The installer validates the prerequisites and exact documented dependency
versions before building. If Open CASCADE Technology is missing, it asks before
running `brew install opencascade`. It builds and verifies LookSTEP before
touching an installed copy, moves an older copy to Trash, installs the app in
`/Applications`, refreshes Finder's extension registration, and opens LookSTEP
once.

Use `bash install.sh --user` to install in `~/Applications`, or
`bash install.sh --help` to see every option. Keep only one installed LookSTEP
copy so Finder does not discover competing versions of its preview extension.

## Manual build

### 1. Install the tools

Install Xcode from Apple and Open CASCADE Technology with Homebrew:

```sh
brew install opencascade
```

OCCT 7.9.3 is the known-good revision for this source release. The exact OCCT,
FreeType, libpng, and oneTBB versions represented by the checked-in notices are
listed in [THIRD_PARTY.md](THIRD_PARTY.md).

### 2. Build in Xcode

Open `StepLook/StepLook.xcodeproj`, choose the `LookSTEP` scheme and **My Mac**,
then build or run.

For a command-line Release build with local ad-hoc signing:

```sh
xcodebuild \
  -project StepLook/StepLook.xcodeproj \
  -scheme LookSTEP \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  "OCCT_ROOT=$(brew --prefix opencascade)" \
  "HOMEBREW_PREFIX=$(brew --prefix)" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build
```

The finished app is at
`build/DerivedData/Build/Products/Release/LookSTEP.app`. Use `bash install.sh`
for a recoverable installation instead of copying a new app over an old bundle.

## Test

Run the Swift and import-service tests from Xcode, or use:

```sh
xcodebuild \
  -project StepLook/StepLook.xcodeproj \
  -scheme LookSTEP \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/TestDerivedData \
  "OCCT_ROOT=$(brew --prefix opencascade)" \
  "HOMEBREW_PREFIX=$(brew --prefix)" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  test
```

Run the installer's mocked success and failure checks with:

```sh
Tests/install_script_tests.sh
```

Test STEP files are not included unless their licenses allow redistribution.
Use your own local files for additional checks, and keep confidential models
outside Git.

## Try the Finder preview

After installation, select a `.step` or `.stp` file in Finder and press
Spacebar, or use Finder's Column View preview pane. Finder may take a moment to
register a newly installed extension.

The LookSTEP app is also a diagnostic host. Open a file there when you need a
clearer import status or incomplete-geometry count.

## Remove LookSTEP

Move `LookSTEP.app` from `/Applications` to Trash in Finder. If you installed
with `--user`, move it from your personal Applications folder instead. Finder
may continue showing an already-open preview until the Quick Look window is
closed.

LookSTEP's versioned mesh cache is stored separately in the normal macOS user
cache location. Removing the app does not delete your STEP files.

## Troubleshooting

### Xcode is not ready

Open Xcode once and allow it to finish installing components. If command-line
tools still point somewhere else, select the installed Xcode in **Xcode >
Settings > Locations > Command Line Tools**.

### Homebrew or OCCT cannot be found

Confirm that Homebrew and Open CASCADE Technology are available:

```sh
/opt/homebrew/bin/brew --prefix
/opt/homebrew/bin/brew --prefix opencascade
```

The installer also checks `/opt/homebrew/bin/brew` when `brew` is not on the
shell's `PATH`.

### A dependency version does not match

The Release app bundles OCCT and several libraries. Every build path stops when
their installed versions differ from [THIRD_PARTY.md](THIRD_PARTY.md), because
shipping different binaries with stale source checksums or notices would be
misleading. This release supports the exact versions listed there. Before
intentionally supporting a newer dependency set, update that register, its
checksums, the expected versions in the validator, and all affected notices.

### A model does not preview

Open the same file in the LookSTEP app. Large or unusually complex models can
reach the bounded preview timeout; this is intentional failure handling rather
than a crash.

### Finder does not use LookSTEP

Confirm that only one copy of `LookSTEP.app` exists in `/Applications` or
`~/Applications` and that it has been opened once. LookSTEP intentionally does
not replace the document icon supplied by your default STEP application.
