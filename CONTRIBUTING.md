# Contributing

Contributions that make STEP previews faster, clearer, or more reliable are welcome.

## Before opening a change

1. Keep the scope focused on STEP import, preview caching, Finder preview behavior, or the small diagnostic host app.
2. Add or update a regression test for reproducible geometry, cache, color, transform, or failure-handling changes.
3. Run the `LookSTEP` test scheme on an Apple Silicon Mac.
4. Describe the user-visible result and any import-time, memory, or triangle-count effect.

If a change touches `install.sh`, also run `Tests/install_script_tests.sh`.

## Architecture boundaries

- Open CASCADE Technology is confined to STEP/XCAF import and tessellation for the preview path.
- RealityKit renders Finder previews.
- The preview cache is a versioned boundary between import and display.
- Assembly definitions and occurrences must stay distinct; do not irreversibly flatten assemblies.
- Incomplete geometry must produce a diagnostic or a clear failure, never silent success.

## Test models and provenance

Do not commit confidential, proprietary, or personally sourced STEP files.

A fixture may be added only when it is independently created or redistributable. Include its source, exact license, and any attribution requirements. If a failing model cannot be shared, reduce it to a new non-confidential reproduction or describe the observed metrics without uploading the file.

Record third-party provenance and license obligations before adding code, binary libraries, or visual assets. Preserve all required notices.

## Contribution provenance

Submit only work you have the right to share. Contributions must be independently written from public documentation, properly licensed dependencies, and the behavior described in this repository.

Never commit private CAD files, generated caches, signing material, machine-specific data, or personal contact details. Keep commits bounded and name them for the user-visible or architectural result.
