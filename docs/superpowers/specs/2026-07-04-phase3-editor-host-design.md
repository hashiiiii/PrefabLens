# PrefabLens Phase 3 設計 — Unity Editor ホスト(ウォーキングスケルトン)

- **日付**: 2026-07-04
- **ステータス**: ドラフト(ユーザーレビュー待ち)
- **親仕様**: `2026-06-29-unity-prefab-diff-design.md` §6.3・§7・§8
- **ユーザー決定(2026-07-04)**: CLI は GitHub Releases から取得(将来 homebrew tap、tap は別リポジトリ案)/ 初回スコープは git HEAD vs 作業ツリー / UIToolkit + Unity 2022.3 LTS+

Editor を離れずに「選択した prefab の未コミット変更」を意味的 diff で確認できる最小の縦切りを作る。CLI をサブプロセスで叩き stdout の JSON(diff.v2)を描画する(親仕様 §6.3 の通り、ネイティブ連携なし)。

## スコープ

### 初回に入れる

1. **リリースパイプライン**(前提インフラ): tag `v*` push で GitHub Actions が zig クロスコンパイル(macos-aarch64 / macos-x86_64 / linux-x86_64 / windows-x86_64)し、`prefablens-<target>.zip` を GitHub Release に添付。zig はクロスコンパイルが素で通るためビルドマトリクス不要(1 ランナーで 4 ターゲット)
2. **CLI の薄い拡張**: `--git REF PATH`(operand 2 個)= 「REF vs 作業ツリー」。既存の `--git REF REF PATH` はそのまま。git ロジックを CLI に集約し、C# 側での `git show` 再実装を避ける(親仕様 §6.1 の「後続の薄いエイリアス」)
3. **Unity package**(`/editor`、UPM): prefab を選択 → メニューで diff 表示

### 初回は延期

- homebrew tap(別リポジトリ `homebrew-prefablens` 案。Releases のアセットをそのまま参照できる)
- 任意 2 ref 比較の UI、シーン内オブジェクトとの対応づけ、P/Invoke 化
- Unity CI(game-ci)での EditMode テスト自動実行(テスト自体は書く。ローカル実行)

## リリースパイプライン

`.github/workflows/release.yml`(tag `v*` push):

```
zig build cli -Dtarget=aarch64-macos -Doptimize=ReleaseSafe  → zip → prefablens-macos-arm64.zip
同様に x86_64-macos / x86_64-linux-gnu / x86_64-windows      → gh release upload
```

- アセットは **zip 統一**(C# の `System.IO.Compression.ZipFile` が全プラットフォームで扱えるため。tar.gz は Unity 側で展開手段がない)
- 中身は単一バイナリ `prefablens`(win は `prefablens.exe`)
- build.zig に `cli` ステップ(install 相当)が無ければ追加する(現状は default install のみ)

## Unity package 構成

```
/editor
  package.json                     com.hashiiiii.prefablens(Editor 専用、unity: 2022.3)
  Editor/
    PrefabLens.Editor.asmdef       Editor プラットフォームのみ、Newtonsoft 参照
    PrefabLensWindow.cs            EditorWindow(UIToolkit)
    Cli.cs                         探索・ダウンロード・実行(サブプロセス)
    DiffModel.cs                   diff.v2 の C# モデル + Newtonsoft パース
  Tests/Editor/                    EditMode テスト(パース・URL 選択の純関数)
```

- JSON は `com.unity.nuget.newtonsoft-json` 依存で読む(kind による NodeDiff の分岐は JObject 経由の手書きマッピング。JsonUtility はユニオン・null を扱えない)

### Cli.cs(探索 → ダウンロード → 実行)

1. **探索**: EditorPrefs `PrefabLens.CliPath`(手動指定、最優先)→ 既定ダウンロード先 `Library/PrefabLens/<VER>/prefablens(.exe)` → 無ければダウンロード提案
2. **ダウンロード**: 固定バージョン定数 `CliVersion`(package と同時に更新)から
   `https://github.com/hashiiiii/PrefabLens/releases/download/v<VER>/prefablens-<target>.zip`
   を取得 → `Library/PrefabLens/<VER>/` に展開 → unix は実行権限付与。ターゲット判定は `RuntimeInformation`(Editor の OS/Arch)
3. **実行**: プロジェクトルート(`Application.dataPath/..`)を cwd に
   `prefablens --git HEAD "<assetPath>" --json` → stdout を parse。exit≠0 は stderr をそのまま表示
4. **guid 解決**: CLI 単体実行では unresolvedGuids が残るため、Editor 側で `AssetDatabase.GUIDToAssetPath()` を使い **完全解決**して `resolved` を上書き(Chrome 版より強い解決が Editor の存在意義)

### PrefabLensWindow.cs

- メニュー: `Window/PrefabLens`、および Project ウィンドウのコンテキスト `Assets/PrefabLens: Diff vs HEAD`(.prefab / .unity / .asset で有効)
- UIToolkit `TreeView` 1 本: ノード(GameObject / PrefabInstance)→ コンポーネント → フィールド行(label + before → after)。status で色分け(added/removed/modified)、Chrome 版レンダラと同じ配色トーン
- 状態表示: CLI 未取得(Download ボタン)/ 実行中 / エラー(stderr)/ No semantic changes
- 選択変更に自動追従はしない(明示的に Refresh ボタン。YAGNI)

## エラーハンドリング

| ケース | 挙動 |
|---|---|
| CLI 不在 | ウィンドウ内に Download ボタン + 手動パス設定への導線 |
| ダウンロード失敗 | エラー表示(URL 付き)。手動配置の案内 |
| 非 git リポジトリ / ref 不在 | CLI の stderr をそのまま表示(CLI 側のメッセージが一次情報)|
| JSON パース失敗 | 「CLI バージョン不一致の可能性」+ 生 stdout 先頭を表示 |

## テスト戦略(親仕様 §7)

- **Zig**: `--git REF PATH`(worktree エイリアス)の parseArgs / run テストを既存 CLI テストに追加(CI で実行)
- **C# EditMode**: DiffModel パース(golden JSON 文字列 → モデル)、release URL/ターゲット選択の純関数、Cli 引数組み立て。ローカルの Unity Test Runner で実行(CI 化は backlog)
- **手動スモーク**: ユーザーの Unity プロジェクトで prefab を変更 → Diff vs HEAD 表示を確認

## PR 分割

| PR | 内容 | マージ |
|---|---|---|
| a | CLI worktree エイリアス + release workflow + 初回タグ手順 | 機能本体、ユーザー確認 |
| b | editor package(Cli/DiffModel/Window + EditMode テスト) | 機能本体、ユーザー確認 |

## 未決事項(レビューで確認)

- package 名 `com.hashiiiii.prefablens` でよいか
- 初回リリースタグは `v0.1.0` でよいか(拡張・CLI と同一バージョン系列)
