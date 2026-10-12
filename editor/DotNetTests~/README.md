# DotNetTests~

This project runs the tests in `../Tests/Editor` with the .NET SDK, without a Unity installation.

- `Package/` compiles `../Editor/*.cs` for `netstandard2.1` with C# 9, matching Unity 2022.3. It uses minimal Unity API stubs in `Package/Stubs/`.
- `Tests/` links `../Tests/Editor/*.cs` and runs them with NUnit via `dotnet test`.

The trailing `~` hides this test folder from Unity's asset importer when the package is installed through UPM.

Run from `editor/`:

```sh
dotnet test DotNetTests~/Tests
```

## Caveats

The stubs only prove that the code compiles against hand-written Unity signatures.
They do not cover differences from the real Unity API or the runtime behavior of `PrefabLensWindow`.
Open the package in Unity 2022.3 LTS, the declared minimum.
Run the EditMode tests and check `Window > PrefabLens` in the real Editor.
