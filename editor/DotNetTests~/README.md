# DotNetTests~

Runs the Unity EditMode tests in `../Tests/Editor` on the plain dotnet SDK, without a Unity installation.

- `Package/` compiles `../Editor/*.cs` as `netstandard2.1` + C# 9 — the same API surface and language version Unity 2022.3 uses — against minimal Unity API stubs (`Package/Stubs/`).
- `Tests/` links `../Tests/Editor/*.cs` and runs them with NUnit via `dotnet test`.

The trailing `~` hides this folder from the Unity asset importer, so the package stays clean when installed via UPM.

Run from `editor/`:

```sh
dotnet test DotNetTests~/Tests
```

## Caveats

The stubs only prove the code compiles against hand-written Unity signatures. Divergence from the real Unity API and the runtime behavior of `PrefabLensWindow` are not covered here — verify those by opening the package in a real Unity Editor (2022.3 LTS, the declared minimum) and running the EditMode tests plus a Window/PrefabLens smoke test.
