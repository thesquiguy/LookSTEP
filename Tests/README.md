# Test Strategy

Tests are organized around observable correctness rather than implementation details.

## Automated checks

- Nested occurrence transforms
- Unique-definition instancing
- Face/part/fallback color precedence
- Unit normalization and bounds
- Cache key compatibility and corruption recovery
- Atomic publication and concurrent request coordination
- Cancellation and stale-result rejection
- Visibility state transitions
- Measurement dispatch and unit formatting
- Exact-section job invalidation
- Installer prerequisite, upgrade-backup, build-failure, and signature-failure paths
- Refusal to install a build whose import service cannot load its bundled OCCT
  libraries, which would otherwise install cleanly and fail every preview

Run the source installer checks with `Tests/install_script_tests.sh`.
Run the shared LookSTEP empty/loading/failure accessibility-state contract
without launching the app with `Tests/step_accessibility_status_tests.sh`.
Run the production LookSTEP import-client request ownership contract without
launching the app with `Tests/step_import_client_request_slot_tests.sh`.
Run the optimized production cache-envelope, atomic source-snapshot,
full-digest replacement, metadata-only identity refresh, transient-read
preservation, cold-import source-identity, and mid-hit source-replacement
integrity contracts without launching an app with
`Tests/step_cache_envelope_tests.sh`.
The restricted command-line harness compiles a test-only seam that bypasses
only `NSFileCoordinator` transport, which is unavailable in that sandbox; the
envelope, archive decoder, source snapshots, and stale-hit rejection are the
same production code. Coordinated cache I/O remains covered by the hosted
LookSTEP suite.
Run the optimized production mesh-allocation preflight contract without
launching an app with `Tests/step_mesh_archive_allocation_tests.sh`.
Run the optimized production XPC cancellation-ledger bound and expiry contract
without launching an app with `Tests/step_import_cancellation_ledger_tests.sh`.
Run the optimized production XPC source-descriptor and staging cleanup contract
without launching an app with `Tests/step_import_staging_tests.sh`.
Run the optimized production client request-slot and XPC connection-lifetime
contract without launching an app with
`Tests/step_import_client_request_slot_tests.sh`. It proves stale-request
rejection, exact-once teardown, connection retention until teardown, and
release after terminal or external invalidation.
After an optimized LookSTEP build, run the real sandboxed XPC cancellation,
teardown, and restart probe without a GUI host with
`Tests/step_import_client_xpc_probe.sh`.

Profile the exact optimized XPC importer without Finder or renderer timing with
`Tests/step_import_performance_probe.sh PRIVACY_SAFE_ID SOURCE_PATH
SIMPLIFICATION_LEVEL`. The probe uses the installed Release service by default,
allows a 120-second diagnostic import, and emits only aggregate JSON metrics;
it never prints the source path.

## Performance reports

Record time to first pixel and peak memory for the size classes in `README.md`. Reports also include cache decode, STEP/XCAF transfer, tessellation, RealityKit/AIS presentation, triangle count, definitions, occurrences, and failed faces/bodies.

## Visual checks

Use stable camera poses and image comparisons for transforms, colors, missing geometry, feature edges, silhouettes, clipping, and selection highlighting. Keep tolerances explicit and review meaningful rendering changes manually.
