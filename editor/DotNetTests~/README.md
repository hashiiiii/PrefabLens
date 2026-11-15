# DotNetTests~

This project compiles the Unity Editor package and runs its Editor tests with the .NET SDK, without installing Unity.  
The `~` in the folder name keeps Unity from importing it when the package is installed through UPM.

The package project targets `netstandard2.1` with C# 9, matching Unity 2022.3.  
It compiles `../Editor/*.cs` against hand-written Unity API stubs.  
The test project links `../Tests/Editor/*.cs` and runs them with NUnit; tests that exercise CLI discovery and installation use real native CLI binaries.

From the repository root, build both CLI test binaries and run the tests:

```sh
zig build test-installation-binaries -Doptimize=ReleaseSafe
PREFABLENS_TEST_BIN_DIR="$PWD/zig-out/bin" \
PREFABLENS_TEST_ALT_BIN_DIR="$PWD/zig-out/test-alternate-bin" \
  dotnet test editor/DotNetTests~/Tests
```

The .NET run checks compilation against the declared Unity API signatures and exercises the Editor code and CLI integration.  
It does not verify behavior inside Unity.  
To check the real Editor integration, open `editor/` in Unity 2022.3 LTS, run the EditMode tests, and open **Window > PrefabLens**.
