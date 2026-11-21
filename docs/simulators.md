# Local iOS simulator workflow

Build This Please uses the shared Keinois simulator pool for iOS execution, including Example UI tests. Swift package unit tests and generic iOS Simulator builds remain boot-free. The Example UI tests use mock data; do not treat them as live SDK or App Attest verification.

Use the stable task ID already assigned to your session. Normal runs use one of the two standard pool iPhones. For a specific provisioned runtime and device pass both exact flags. Use the exact leased UUID for Xcode. This example uses the mock UI suite with stock mode until a slim profile for it has been tested. Use a task-specific DerivedData path.

```sh
python3 scripts/simulator.py --task "$KEINOIS_IOS_TASK_ID" --features mock-ui \
  -- /usr/bin/xcrun xcodebuild test \
  -project Examples/BuildThisPleaseExample/BuildThisPleaseExample.xcodeproj \
  -scheme BuildThisPleaseExample \
  -destination 'platform=iOS Simulator,id={udid}' \
  -parallel-testing-enabled NO -derivedDataPath "$TASK_DERIVED_DATA"
```

The job ending pauses the device; it remains reserved with its data. Start the next run with the same task ID to resume. Do not erase, create, or boot outside the shared manager. Read the [shared flow](https://github.com/keinois/keinois-brain/tree/main/tools/ios-simulator-pool) for a release after the task ends, reset confirmation, and recovery.
