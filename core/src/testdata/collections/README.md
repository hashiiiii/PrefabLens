# Collection merge fixtures

Unity `6000.7.0a2` generated the 14 three-way cases and their fixed source GUIDs.
Three additional replay cases use Unity row templates with an omitted serialized member.
Two source-context cases use these templates to change the source independently of the Variant.
`expected-runtime.json` records the required runtime values and the conflict choice for all 19 cases.
These fixtures do not establish exact Unity `6000.6` runtime coverage.

The `nested` files contain a separate source and two levels of Prefab Variants from the same Editor.
The source lookup tests use their actual target file IDs.

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

To regenerate inputs in a disposable copy, run `EdgeAudit.Generate`, then `EdgeAudit.GenerateDictionaryVariants`.
Generation can change file IDs. Copy the generated source prefabs and metadata with the cases.

The `packed` directory contains signed and empty `int[]` files from Unity `6000.5.2f1` and `6000.7.0a2`.
The `replay` directory records the sparse row templates and their source context.
