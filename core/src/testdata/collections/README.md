# Collection merge fixtures

Unity `6000.7.0a2` generated and verified the three array cases.
Their existing serialized values and script GUID remain in the fixture files.
`expected-runtime.json` records the runtime values and conflict choice for each case.
These fixtures do not establish exact Unity `6000.6` runtime coverage.

Copy this directory to a temporary directory before opening its Unity project.
Keep `cases`, `expected-runtime.json`, and `unity` together.
Run the fixture test and export the outputs into that copy:

```sh
zig build test-collection-fixtures -- <copy>
```

This checks exact output bytes against the Unity-verified `expected.prefab` files.
It reads field types from real temporary Git revisions.
Then run the Editor with these arguments:

```text
-batchmode -nographics -projectPath <copy>/unity -executeMethod CollectionAcceptance.Verify -quit -logFile <copy>/acceptance.log
```

The verifier loads every result with `PrefabUtility.LoadPrefabContents` and checks its values.
It fails for missing results, conflict markers, missing components, or unexpected values.
Each successful case records the exact Editor version in `unity-result.txt`.

To regenerate inputs in a disposable copy, run `EdgeAudit.Generate`.
Generation can change file IDs. Copy the generated Prefab and metadata with the cases.

The `packed` directory contains signed and empty `int[]` files from Unity `6000.5.2f1` and `6000.7.0a2`.
The recorded `unity-result.txt` files preserve the Editor versions used for those fixtures.
