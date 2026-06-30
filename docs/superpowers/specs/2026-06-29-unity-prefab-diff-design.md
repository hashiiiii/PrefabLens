# PrefabLens — 設計ドキュメント（アーキテクチャ & ロードマップ）

- **プロダクト名**: PrefabLens（リポジトリ: `PrefabLens`）。「Unity」は商標のため固有名は造語とし、説明に "for Unity" を添える方針。
- **日付**: 2026-06-29
- **ステータス**: 承認済み（Phase 1 を実装計画フェーズへ）
- **アーキテクチャ**: マルチホスト共通コア（Zig 製の純粋な diff エンジンを、CLI / Chrome 拡張 / Unity Editor / AI(MCP) の各ホストが再利用）
- **対象**: Unity の prefab/scene/asset を意味的に diff し、ローカル（CLI・Editor）と GitHub PR（Chrome 拡張）の両方で分かりやすく表示する OSS ツール

---

## 1. 概要 / 目的

Unity の prefab・scene・ScriptableObject は YAML テキストだが、人間がレビューするための形式ではない。生 YAML の diff は `{fileID: 11500000, guid: abc..., type: 3}` のような参照や、コンポーネント追加で複数箇所に散る行差分のせいで実質レビュー不能になる。

PrefabLens は **Unity アセットを意味単位（GameObject・コンポーネント・フィールド）で diff** し、それを複数の場所で読める形に表示する：

- **ローカル**: CLI（ターミナル）と Unity Editor（EditorWindow）で、手元の変更を即座に確認。
- **GitHub PR**: Chrome 拡張で「Files changed」にインライン表示し、レビューを実用化。
- **AI 連携**: 構造化 diff を MCP 経由で AI エージェント（Unity の AI Agents 含む）へ渡し、要約・リスク指摘・自動レビューを可能にする。

中核は **Zig 製の純粋な diff エンジン（共通コア）**。各ホストはこのコアを再利用する薄いフロントエンドであり、コアは 1 つのソースから WASM / ネイティブの両方へコンパイルされる。**性能を最優先**し、Chrome ホストは**バックエンド無し・費用ゼロ**で動く。

### ゴール（成功基準）

- prefab/scene/asset の差分を「追加/削除されたコンポーネント・変更されたフィールド（旧→新）」として読める形で表示する。
- `fileID`/`guid` 参照を実名（型名・スクリプト名・対象オブジェクト名）に解決する（L2）。
- 1 つの共通コアを、CLI / Chrome / Editor / AI が再利用する（重複実装ゼロ）。
- 性能予算（§5.7）を CI で強制する。

---

## 2. 背景・既存ツール調査

| ツール | 何をする | 本構想との差 |
|---|---|---|
| UnityYAMLMerge (SmartMerge) | Unity 公式。prefab/scene YAML を意味的に**マージ**する CLI | マージ専用。見やすい diff 表示ではない |
| UniMerge | Unity Editor 内で色分け diff/マージ | Editor 専用。GitHub PR では使えない |
| endaye/unity-prefab-compare-tool | prefab 比較 | Editor ツール、PR 連携なし |
| Unity YAML Prefab Diff Visualizer（個人作） | Editor 内で GUID→名前解決し構造表示 | Editor 専用。Chrome 拡張で PR に出す発想は無い |
| KittyCAD diff-viewer-extension | GitHub PR diff を上書きして 3D CAD を表示する Chrome 拡張 | 対象が CAD。「PR diff をブラウザ拡張で上書きする」参考事例 |

**結論**: 既存ツールには「ローカル表示（Editor/CLI）」という大きな価値があるが、いずれも単一ホストに閉じている。PrefabLens は**1 つの共通コアを、ローカル（CLI/Editor）と GitHub PR（Chrome）と AI(MCP) の全てで再利用**する点が新しく、空白地帯を埋める。

---

## 3. 確定した設計判断

| 項目 | 決定 | 理由 |
|---|---|---|
| diff の深さ | **L2: 名前解決つき構造 diff** | PR/ローカルで最も実用的。fileID/guid を実名解決 |
| アーキテクチャ | **マルチホスト共通コア** | コアを純関数・明確 ABI で切り、全ホストが再利用 |
| エンジン言語 | **Zig** | GC/ランタイム無しで最小 WASM・最速。1 ソースから WASM/ネイティブ両対応 |
| 責務分担 | **案1: Thin Shell + Fat Core** | 解析/差分を Zig に集約。ホストは I/O・解決・描画のみ |
| ビルド順 | **Core+CLI → Chrome → Editor → AI** | 最単純な CLI でエンジンを実証→難しい Chrome のリスク低減 |
| 対象アセット | **prefab / scene / asset（3 種）** | YAML 形式は共通、コア解析モデルは 1 つで済む |
| 名前解決の seam | **ホスト別の解決器を差し替え** | Chrome=GitHub API / CLI=.meta 走査 / Editor=AssetDatabase |
| Chrome ホスト | **拡張内完結（WASM・バックエンド無し）／PAT 認証／インライン `[Raw\|Semantic]` トグル／Shadow DOM** | 運用費ゼロ・レビューの流れを崩さない |
| CLI/Editor ホスト | **ネイティブ・ローカル完結** | ローカルに全ファイルがあり guid 解決が完全かつ高速 |

---

## 4. アーキテクチャ（マルチホスト）

### 4.1 全体図

```
                    ┌─────────────────────────────┐
                    │  Zig 共通コア（純粋な差分エンジン）│
                    │  parse → fileID突合 → diff   │
                    │  → 構造化diff(JSON/struct)    │
                    │  ＋ 未解決guid集合を返す       │
                    └──────────────┬──────────────┘
        ┌──────────────┬───────────┼───────────┬──────────────┐
        ▼              ▼           ▼           ▼              ▼
   ┌─────────┐   ┌─────────┐  ┌─────────┐ ┌──────────┐  ┌──────────┐
   │ CLI     │   │ Chrome  │  │ Unity   │ │ AI / MCP │  │ (将来)   │
   │(native) │   │ (WASM)  │  │ Editor  │ │          │  │ VS Code  │
   │Phase 1  │   │Phase 2  │  │(C#)     │ │ Phase 4  │  │ ...      │
   │.meta走査│   │GitHub   │  │Phase 3  │ │構造化diff│  │          │
   │で解決   │   │APIで解決│  │AssetDB  │ │をLLMへ   │  │          │
   │ターミナル│   │Shadow   │  │で解決   │ │MCPツール │  │          │
   │/JSON/HTML│  │DOM描画  │  │Editor   │ │として公開│  │          │
   │         │   │         │  │Window   │ │          │  │          │
   └─────────┘   └─────────┘  └─────────┘ └──────────┘  └──────────┘
```

> MV3 の "Service Worker"（Chrome ホスト内）は拡張機能のバックグラウンド・スクリプトであり、ユーザーのブラウザ内で動く。Web のバックエンドサーバではない。本ツールに運用サーバは存在しない。

### 4.2 共通コアとホストの責務境界

- **共通コア（Zig）**: 入力＝前後 2 版のバイト列。出力＝構造化 diff ＋未解決 guid 集合。**純関数・グローバル状態なし・I/O なし**。組み込み型（静的 classID テーブル）とローカル参照（同一ファイル内 fileID）は内部解決する。
- **ホスト**: ①差分元の調達（ファイル/git ref/blob）②未解決 guid の解決（ホスト別の解決器）③描画（ターミナル/DOM/EditorWindow）④認証・設定。

### 4.3 名前解決の seam（ホスト別の解決器）

| ホスト | guid → アセットパスの解決方法 | ネットワーク |
|---|---|---|
| CLI | ローカルの `.meta` を走査して guid→path 索引を構築 | 不要 |
| Unity Editor | `AssetDatabase.GUIDToAssetPath()` 一発 | 不要 |
| Chrome 拡張 | ①PR 変更 `.meta` ②コード検索 `"<guid>" path:*.meta` ③キャッシュ | 必要（少数） |

> コアが「未解決 guid 集合を返す → ホストが解決」という共通の継ぎ目を持つため、各ホストは**同じ seam に別の解決器を差すだけ**。ローカルホストでは解決が完全かつ高速になる。

---

## 5. Zig 共通コア設計（ホスト非依存）

### 5.1 Unity YAML の構造

```
%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!1 &123456789          ← classID=1(GameObject), fileID=123456789
GameObject:
  m_Name: Player
  m_Component:
    - component: {fileID: 234}     ← ローカル参照
    - component: {fileID: 345}
--- !u!114 &345              ← classID=114(MonoBehaviour)
MonoBehaviour:
  m_GameObject: {fileID: 123456789}
  m_Script: {fileID: 11500000, guid: abc.., type: 3}  ← 外部参照(guid)
  maxHp: 100
```

1 ファイル = ドキュメントの並び。各ドキュメント = `classID`(`!u!N` タグ) ＋ `fileID`(`&N` アンカー) ＋ 本体マッピング。

### 5.2 データモデル

```zig
Document { class_id: u32, file_id: i64, type_name: []const u8, body: Node }
Node = union { Map(entries), Seq(items), Scalar([]const u8), Ref{fileID, guid?, type?} }
```

- **Scalar は元入力バッファへのスライス参照（ゼロコピー）**。文字列を複製しない。
- **arena アロケータ**で全 Node を確保、diff 1 回ごとに一括解放。

### 5.3 パーサ

- 汎用 YAML ライブラリは使わず、**Unity YAML 限定サブセット専用の一発パス・パーサ**を自作。
  - ブロックスタイル中心、flow は `{fileID:..}` 等の埋め込みのみ、2 スペース固定インデント、エイリアスはドキュメントの `&fileID` のみ。
- インデントスタックでドキュメント群を生成。`{fileID:.., guid:.., type:..}` は Ref ノードとして特別認識。
- malformed 入力に堅牢（フォールバックのためエラーを返す）。

### 5.4 名前解決の 3 分岐（コア内 / ホスト委譲）

| 参照の種類 | 例 | 解決方法 | 担当 |
|---|---|---|---|
| 組み込み classID | `!u!1`, `!u!4`, `!u!114` | Zig 内蔵の静的 classID テーブル → 型名 | コア |
| ローカル参照 | `{fileID: 234}` | 同一ファイル内の同 anchor ドキュメントへ突合 | コア |
| 外部参照(guid) | `{fileID:.., guid:.., type:3}` | 未解決 guid 集合として出力 → ホストが解決 | ホスト |

### 5.5 diff アルゴリズム

```
1. 前後それぞれをパース → Document 群
2. GameObject 階層を再構築（Transform.m_Father/m_Children, m_Component で紐付け）
3. オブジェクトを fileID で突合（前後マッチング）
4. マッチした各オブジェクト → 本体マッピングを再帰的フィールド diff
5. 分類: Added / Removed / Modified / Unchanged
6. GameObject 階層を反映した差分ツリーを生成（Unchanged は畳む）
```

- **突合キー = fileID**。Unity は編集をまたいで安定した fileID を振るため、行位置でなくオブジェクトの同一性で前後対応できる。「コンポーネント追加で複数行がズレる」問題に惑わされない根拠。
- 例外（fileID が変わる稀ケース）には二次マッチ `(型 + m_Name + 親)` の類似度で救済。**Phase 1 は fileID 主・名前フォールバックは後続**。
- フィールド diff は参照を「解決後のアイデンティティ」で比較（ローカル=対象 fileID、外部=guid+fileID）。

### 5.6 コア ABI（WASM / ネイティブ共通）

- コアは C ABI のエクスポートを持ち、**WASM（Chrome 用）とネイティブ静的/動的ライブラリ（CLI/Editor 用）の両方**へコンパイルされる（同一ソース、ターゲット違い）。
- エクスポート: `alloc(len)`, `free(ptr,len)`, `diff(before*, beforeLen, after*, afterLen) -> resultPtr`（長さ前置の JSON バイト列）。
- diff 1 回 = 1 arena、呼出ごとにリセット。グローバル状態なし＝**純関数**で再入可能・テスト容易。
- CLI は同じコアを直接リンク（FFI 不要）。Chrome は WASM をロード。Editor は CLI バイナリをサブプロセスで利用（後で P/Invoke も可）。

### 5.7 性能目標（CI で強制）

| 指標 | 目標 |
|---|---|
| WASM バンドル(gzip) | ≤ 80 KB（上限 150 KB） |
| 典型 prefab(≤200KB) の parse+diff | < 5 ms |
| 巨大 scene(~10MB) の parse+diff | < 150 ms |
| ピークメモリ | input の約 3 倍以内 |
| Chrome のメインスレッド | Web Worker 隔離＝ジャンクゼロ |
| トグル→描画(ネット除く) | < 300 ms |
| 巨大ファイルガード | 25MB 超は「クリックで描画」（Chrome） |

---

## 6. ホスト別設計

### 6.1 CLI ホスト（Phase 1 = v1）

- **入力**: 2 つのファイルパス、または git ref（例: `PrefabLens HEAD~1 HEAD path/to/Foo.prefab`、`--staged`、ワーキングツリー比較）。git 連携は `git show <ref>:<path>` をサブプロセスで取得。
- **名前解決**: カレントの Unity プロジェクトの `.meta` を走査して guid→path 索引を構築（キャッシュ可）。ローカルなので完全解決。
- **出力**:
  - 既定: **ANSI カラーのツリー表示**（追加=緑/削除=赤/変更=黄、GameObject 階層、フィールド旧→新）。
  - `--json`: 構造化 diff をそのまま（CI・他ツール・AI 連携用）。
  - `--html`: 自己完結 HTML（共有用）。
- **用途**: コミット前の確認、`git difftool` 連携、CI でのレビュー補助。

### 6.2 Chrome 拡張ホスト（Phase 2）

- **構成**: Content Script（検出・トグル注入・オーケストレーション）／Web Worker（WASM ロード・コア呼出、メインスレッド隔離）／background Service Worker（PAT・GitHub API・guid 解決・キャッシュ）／Renderer（Shadow DOM ツリー）／Options（PAT 入力・baseURL）。
- **検出**: Files changed 内で `*.prefab` / `*.unity` / `*.asset` を特定。GitHub の SPA・遅延ロードに `MutationObserver` で追従、セレクタは防御的に。
- **blob 取得**: PR の base/head SHA から前後内容を取得（Contents/Blobs API）。追加/削除は片側空。
- **guid 解決**: ①PR 変更 `.meta` ②コード検索 `"<guid>" path:*.meta` ③`repo+sha` でキャッシュ ④未解決はフォールバック表示。
- **認証**: **PAT のみ**（`getToken()` を返すプロバイダ層の裏に置き、将来 OAuth を差込可）。`chrome.storage` 保存。**baseURL 設定**で github.com / GHEC / GHES をカバー。
- **表示**: インライン `[Raw|Semantic]` トグルで生 diff と意味的 diff を相互切替。Shadow DOM で GitHub の CSS と非干渉、light/dark 追従。

### 6.3 Unity Editor ホスト（Phase 3）

- **実装**: EditorWindow（IMGUI/UIToolkit）。**CLI バイナリをサブプロセスで叩き、stdout の JSON を受け取って描画**（ネイティブ連携の複雑さゼロ。後で密結合が要れば P/Invoke 化）。
- **名前解決**: `AssetDatabase.GUIDToAssetPath()` で完全解決。
- **差分元**: git（HEAD/ステージ/任意 ref）との比較、または 2 つの prefab/版の比較。
- **用途**: Editor を離れずに変更を確認、シーン内オブジェクトとの対応づけ。

### 6.4 AI / MCP 連携（Phase 4）

- **公開形態**: **MCP サーバ**として「2 ref 間の prefab/scene 意味的 diff を返す」ツールを提供。入力は構造化 diff（JSON）。
- **ユースケース**: 変更の自然言語要約、リスクの高い変更の指摘、PR の自動レビュー、Unity の AI Agents からの呼出。
- **前提**: コアの構造化 JSON 出力がそのまま LLM 入力になる（既存設計の自然な拡張）。

---

## 7. テスト戦略

- **Zig コア**: `std.testing` でパーサ＋diff の単体テスト。フィクスチャ群（追加/削除コンポーネント、reparent、ネスト prefab、巨大 scene、fileID 衝突）。diff 出力のゴールデンファイル比較。malformed 入力のファジング。
- **CLI（Phase 1 の主テストハーネス）**: フィクスチャを CLI に通し、ANSI/JSON 出力をゴールデン照合。コアを端から端まで検証する最短経路。
- **WASM 境界（Phase 2）**: コンパイル済 WASM を Node で実行し JSON 出力をゴールデン照合。
- **TS（Phase 2）**: GitHub API クライアント（fetch モック）、guid 解決＋キャッシュ、レンダラの DOM スナップショット。E2E は Playwright で保存済み PR ページ HTML に対し検出→トグル→描画を検証。
- **Editor（Phase 3）**: サブプロセス呼出と JSON パースの単体、EditorWindow のスモーク。
- **CI**: GitHub Actions で Zig→WASM/ネイティブ ビルド／Zig テスト／CLI ゴールデン／Node WASM テスト／TS・Playwright／**WASM バンドルサイズ予算チェック**（上限超で失敗）。

---

## 8. プロジェクト構成（モノレポ）

```
/core        ← Zig: parser, model, diff（build.zig が WASM/ネイティブlib/CLI を出力）
  src/
  tests/fixtures/
/cli         ← Zig: core を直接リンクする薄い CLI フロントエンド（Phase 1）
/extension   ← TS(MV3) Chrome ホスト（Phase 2）
  src/{content,worker,background,renderer,options}/
  manifest.json
/editor      ← Unity package（C#）Editor ホスト（Phase 3）。CLI をサブプロセス利用
/mcp         ← MCP サーバ（Phase 4）。構造化 diff を AI へ公開
/docs
```

> `/core` と `/cli` は 1 つの Zig ビルドにまとめてもよい（lib ターゲット＋bin ターゲット）。WASM は内部ビルド成果物であって公開パッケージではない。

---

## 9. フェーズ / スコープ

各フェーズは独立して出荷可能で、**すべて同じ Zig 共通コアを再利用**する。

### Phase 1（v1）— Core + CLI

**入れる**: Zig 共通コア（パーサ・fileID 突合・フィールド diff・静的 classID テーブル・ローカル参照解決・構造化 JSON 出力）／CLI ホスト（ファイル/git ref 入力、ローカル `.meta` 走査による guid 解決、ANSI ツリー・`--json`・`--html` 出力）／フィクスチャ＋ゴールデンテスト／CI と性能予算。

**入れない**: Chrome/Editor/AI ホスト、名前ベース二次マッチング（fileID 主）。

### Phase 2 — Chrome 拡張ホスト

検出・インライン `[Raw|Semantic]` トグル・Shadow DOM レンダラ・GitHub API・PAT 認証（プロバイダ層）・baseURL（github.com/GHEC/GHES）・guid 解決（PR 変更 meta＋コード検索＋キャッシュ）・Web Worker 隔離・WASM サイズ予算。**面は PR Files changed のみ**（commit 比較・blob 単体ビューは後続）。

### Phase 3 — Unity Editor ホスト

EditorWindow、CLI サブプロセス＋JSON 描画、`AssetDatabase` による完全解決、git/版比較。

### Phase 4 — AI / MCP 連携

構造化 diff を MCP ツールとして公開。要約・リスク指摘・自動レビュー・Unity AI Agents 連携。

### 全フェーズ共通で「入れない」（さらに後 / 非目標）

L3 ビジュアル描画 ／ OAuth Device Flow・GitHub App 認証 ／ Firefox・Edge 移植 ／ マージ衝突解決 ／ VS Code 拡張。

> Phase 2 以降は「ホストの追加」であり、Zig 共通コアに手を入れずに足せる。Phase 1 の投資は全フェーズで再利用される。

---

## 10. リスク / 未解決事項

| リスク | 緩和策 |
|---|---|
| GitHub UI 変更で注入が壊れる（Phase 2） | 防御的セレクタ・try/catch・生 diff フォールバック。E2E で早期検知 |
| コード検索 API のレート制限・インデックス遅延（Phase 2） | PR 変更 meta を先に使う／キャッシュ／未解決フォールバック |
| Zig ツールチェーンのバージョンずれ | `build.zig.zon` / `mise.toml` で **0.16.0** に固定。CI で検証 |
| ネイティブバイナリ配布（CLI/Editor） | プラットフォーム別ビルドを CI で生成し Releases 配布。Editor はサブプロセスで CLI を同梱/取得 |
| 巨大 scene の相互参照・ネスト prefab の複雑さ | フィクスチャに含めて段階対応。Phase 1 は fileID 突合を堅実に |
| fileID が変わるケースで誤マッチ | Phase 1 は fileID 主、二次マッチは後続で追加 |
| MCP 連携のスコープ肥大（Phase 4） | 「構造化 diff を返す」最小ツールに限定、要約等はエージェント側に委譲 |
