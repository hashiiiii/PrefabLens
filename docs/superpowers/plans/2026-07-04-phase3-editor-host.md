# Phase 3 Editor Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unity Editor 内で選択 prefab の「HEAD vs 作業ツリー」意味的 diff を表示する(spec: `docs/superpowers/specs/2026-07-04-phase3-editor-host-design.md`、承認済み)。

**Architecture:** CLI サブプロセス + stdout JSON(diff.v2)。CLI は GitHub Releases から自動取得。guid は AssetDatabase で完全解決。

**Tech Stack:** Zig(CLI 拡張)/ GitHub Actions(release)/ C# + UIToolkit + Newtonsoft(editor package)

## Global Constraints

- コミットは 1 行英語 ≤50 字 / 実装は最小限(coding-preferences)/ Unity 2022.3 LTS+
- package 名 `com.hashiiiii.prefablens` / 初回タグ `v0.1.0`(ユーザー確定)
- 検証は exit code を殺さない形で(`cmd > /tmp/out; code=$?`)
- Zig 検証: `zig build test`。C# は EditMode テストを書くが実行はローカル Unity(CI 化 backlog)

---

## PR a — `feat/editor-host`(CLI worktree エイリアス + release workflow)

### Task 1: CLI `--git REF PATH`(REF vs 作業ツリー)

**Files:** Modify `cli/src/main.zig`(parseArgs / run / usage 文言)

**Interfaces:** `--git` は非フラグ operand を 2〜3 個消費。2 個なら `git_ref_after = ""`(空 = 作業ツリー側)。after 側の worktree 読みで FileNotFound は空(= 削除)扱い。

- [ ] parseArgs テスト追加: 2-operand 形式 / 2-operand 直後のフラグ継続 / operand 1 個は MissingOperands → FAIL 確認
- [ ] run テスト追加: 一時 git repo で commit(0.5)→ 作業ツリー変更(0.8)→ `--git HEAD <path> --json` が after 0.8 / 作業ツリーでファイル削除 → exit 0 で removed 出力 → FAIL 確認
- [ ] parseArgs: `--git` の operand 消費を「`--` 始まりでない引数を最大 3 個」に変更、2 個なら worktree モード。usage を `--git <beforeRef> [<afterRef>] <path>` に
- [ ] run: after 側を labeled block 化し、`git_ref_after.len == 0` なら readFile(FileNotFound → 空)
- [ ] `zig build test` PASS → Commit `feat: diff a ref against the working tree`

### Task 2: release workflow

**Files:** Create `.github/workflows/release.yml`

- [ ] tag `v*` push で: mise-action → 4 ターゲットを順に `zig build -Dtarget=<t> -Doptimize=ReleaseSafe` → `prefablens-{macos-arm64,macos-x64,linux-x64,windows-x64}.zip` に zip -j → `gh release create "$GITHUB_REF_NAME" dist/*.zip --generate-notes`(`GH_TOKEN: ${{ github.token }}`、`permissions: contents: write`)
- [ ] ローカル検証: 4 ターゲットのクロスコンパイルが通ることを実際に確認(`zig build -Dtarget=x86_64-windows` 等)
- [ ] Commit `ci: build and attach cli binaries on tag push`

### Task 3: PR a 作成 → CI green → ユーザー確認どおり自己判断可なら squash(機能本体のため原則ユーザー確認、ただし spec 承認済みのため PR 提示のみで続行可)

- [ ] push、PR 作成、CI green 確認。マージ判断は PR b と合わせて最後にユーザーへ

---

## PR b — editor package(PR a の後、同ブランチ継続 or 分岐)

### Task 4: package 骨格 + DiffModel

**Files:** Create `editor/package.json` / `editor/Editor/PrefabLens.Editor.asmdef` / `editor/Editor/DiffModel.cs` / `editor/Tests/Editor/DiffModelTests.cs`(+ Tests asmdef)

- [ ] package.json: name com.hashiiiii.prefablens、unity 2022.3、dependencies に com.unity.nuget.newtonsoft-json
- [ ] DiffModel: diff.v2 の C# クラス群 + `DiffModel.Parse(string json)`(JObject 手書きマッピング、kind で NodeDiff 分岐)+ `ApplyAssetDatabaseResolution(Func<string,string> guidToPath)`(unresolvedGuids を完全解決して resolved を上書き)
- [ ] EditMode テスト: wasm_golden と同じ JSON 文字列 → モデル / 未知 kind・欠損フィールドの耐性 / resolution 上書き
- [ ] Commit `feat: add editor package skeleton and diff model`

### Task 5: Cli.cs(探索・ダウンロード・実行)

**Files:** Create `editor/Editor/Cli.cs` / Test `editor/Tests/Editor/CliTests.cs`

- [ ] 純関数を分離: `ReleaseAssetName(OSPlatform, Architecture)` → `prefablens-macos-arm64.zip` 等 / `DownloadUrl(version, assetName)` / 引数組み立て `BuildArgs(assetPath)` → `--git HEAD "<path>" --json`
- [ ] 探索: EditorPrefs `PrefabLens.CliPath` → `Library/PrefabLens/<VER>/prefablens(.exe)` → null
- [ ] ダウンロード: UnityWebRequest で zip 取得 → ZipFile.ExtractToDirectory → unix chmod +x(Process)
- [ ] 実行: Process(cwd = プロジェクトルート)、stdout/stderr 捕捉、exit≠0 は stderr を返す
- [ ] EditMode テスト: 純関数 3 種
- [ ] Commit `feat: locate download and run the cli`

### Task 6: PrefabLensWindow.cs(UIToolkit)

**Files:** Create `editor/Editor/PrefabLensWindow.cs`

- [ ] `Window/PrefabLens` メニュー + `Assets/PrefabLens: Diff vs HEAD` コンテキスト(.prefab/.unity/.asset で有効)
- [ ] TreeView: ノード → コンポーネント → フィールド(before → after、status 色分け。Chrome 版レンダラと同配色トーン)
- [ ] 状態: CLI 不在(Download ボタン)/ 実行中 / stderr エラー / No semantic changes / Refresh ボタン
- [ ] Commit `feat: add prefab diff editor window`

### Task 7: 仕上げ

- [ ] spec の未決事項欄を確定内容で更新、README 追記は不要(リポジトリ README は未追跡・ユーザー管理)
- [ ] PR 作成 → CI green → ユーザーに PR a/b のマージと v0.1.0 タグ打ちを確認(タグは PR a マージ後でないと Releases が無く、Editor のダウンロードが 404 になる点を明記)

## Self-Review 済み

- spec の全節をタスクに対応付け(リリース=T2、CLI=T1、package=T4-6、テスト戦略=各タスク内)
- 型・命名は spec と一致(CliVersion 定数、EditorPrefs キー、アセット名 4 種)
