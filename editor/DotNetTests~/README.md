# DotNetTests~

This project runs the Unity EditMode tests in `../Tests/Editor` with the .NET SDK, without a Unity installation.

- `Package/` compiles `../Editor/*.cs` for `netstandard2.1` with C# 9. This matches the API surface and language version used by Unity 2022.3. It compiles against minimal Unity API stubs in `Package/Stubs/`.
- `Tests/` links `../Tests/Editor/*.cs` and runs them with NUnit via `dotnet test`.

The trailing `~` hides this folder from the Unity asset importer, so the package stays clean when installed via UPM.

Run from `editor/`:

```sh
dotnet test DotNetTests~/Tests
```

## Caveats

The stubs only prove that the code compiles against hand-written Unity signatures.
They do not cover differences from the real Unity API or the runtime behavior of `PrefabLensWindow`.
Open the package in a real Unity Editor (2022.3 LTS, the declared minimum), then run the EditMode tests and a `Window > PrefabLens` smoke test.
