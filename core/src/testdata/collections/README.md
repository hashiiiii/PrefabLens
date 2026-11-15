# Collection merge fixtures

Unity 6000.7.0a2 generated and verified the three array cases.  
`expected-runtime.json` records the expected runtime values and conflict choice for each case.

Copy this directory to a disposable location before opening its Unity project.  
Keep `cases/`, `expected-runtime.json`, and `unity/` together.  
From the repository root, run the fixture check and export its results to the copy:

```sh
zig build test-collection-fixtures -- "/path/to/collections-copy"
```

The check creates real temporary Git revisions, compares output bytes with each Unity-verified `expected.prefab`, and writes each result to the copy's `cases/<case>/result.prefab`.

Open the copy's `unity/` project in Unity, or run the installed Editor executable in batch mode.  
Replace the paths with your copy and Editor executable:

```sh
"/path/to/Unity" -batchmode -nographics -projectPath "/path/to/collections-copy/unity" -executeMethod CollectionAcceptance.Verify -quit -logFile "/path/to/collections-copy/acceptance.log"
```

The verifier loads each result with `PrefabUtility.LoadPrefabContents` and checks its values.  
It fails for missing results, conflict markers, missing components, or unexpected values.  
Each successful case records the exact Editor version in `unity-result.txt`.

To regenerate the array inputs, run the installed Editor executable against the Unity project in the disposable copy:

```sh
"/path/to/Unity" -batchmode -nographics -projectPath "/path/to/collections-copy/unity" -executeMethod EdgeAudit.Generate -quit -logFile "/path/to/collections-copy/generation.log"
```

Generation can change file IDs.  
Copy the regenerated Prefabs and any updated metadata with the cases.  
The `packed` fixtures contain signed and empty `int[]` cases verified with Unity 6000.5.2f1 and 6000.7.0a2; their `unity-result.txt` files record the Editor versions.
