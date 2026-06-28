# Unity Prefab Diff — 設計ドキュメント

- **日付**: 2026-06-29
- **ステータス**: 承認済み（実装計画フェーズへ）
- **対象**: Unity の prefab/scene/asset を意味的に diff し、GitHub Pull Request のレビュー画面に分かりやすく表示する OSS ツール

---

## 1. 概要 / 目的

Unity の prefab・scene・ScriptableObject は YAML テキストだが、人間がレビューするための形式ではない。GitHub PR で生 YAML の diff を見ても、`{fileID: 11500000, guid: abc..., type: 3}` のような参照や、コンポーネント追加で複数箇所に散る行差分のせいで実質レビュー不能になる。

本ツールは **Unity アセットを意味単位（GameObject・コンポーネント・フィールド）で diff し、その結果を Chrome 拡張で GitHub PR の「Files changed」画面にインライン表示**する。バックエンドサーバを持たず、すべてユーザーのブラウザ内で完結させる（運用費ゼロ・OSS として配布）。**性能を最優先**する。

### ゴール（成功基準）

- prefab/scene/asset の差分を「追加/削除されたコンポーネント・変更されたフィールド（旧→新）」として読める形で表示する。
- `fileID`/`guid` 参照を実名（型名・スクリプト名・対象オブジェクト名）に解決する（L2）。
- バックエンド不要・費用ゼロ・private/public リポジトリ両対応。
- 性能予算（§5.7）を CI で強制する。

---

## 2. 背景・既存ツール調査

| ツール | 何をする | 本構想との差 |
|---|---|---|
| UnityYAMLMerge (SmartMerge) | Unity 公式。prefab/scene YAML を意味的に**マージ**する CLI | マージ専用。PR 上の見やすい diff 表示ではない |
| UniMerge | Unity Editor 内で色分け diff/マージ | Editor 専用。GitHub PR では使えない |
| endaye/unity-prefab-compare-tool | prefab 比較 | Editor ツール、PR 連携なし |
| Unity YAML Prefab Diff Visualizer（個人作） | Editor 内で GUID→名前解決し構造表示 | **Editor 専用**。Chrome 拡張で PR に出す発想は無い |
| KittyCAD diff-viewer-extension | GitHub PR diff を上書きして 3D CAD を表示する Chrome 拡張 | 対象が CAD。だが「PR diff をブラウザ拡張で上書きする」アーキテクチャの参考事例 |

**結論**: 「Unity prefab を意味的に diff し、それを Chrome 拡張で GitHub PR に直接出す」という組み合わせは空白地帯であり、作る価値がある。

---

## 3. 確定した設計判断

| 項目 | 決定 | 理由 |
|---|---|---|
| diff の深さ | **L2: 名前解決つき構造 diff** | PR レビューで最も実用的。fileID/guid を実名解決 |
| 実行場所 | **Chrome 拡張内で完結（WASM・バックエンド無し）** | 運用費ゼロ・プライバシー・配布容易 |
| エンジン言語 | **Zig** | GC/ランタイム無しで最小 WASM・最速。性能最優先に忠実 |
| 責務分担 | **案1: Thin Shell + Fat Core** | 解析/差分を Zig に集約。JS↔WASM 境界を最終 diff のみに絞り性能最大化 |
| 対象アセット | **prefab / scene / asset（3 種）** | YAML 形式は共通、コア解析モデルは 1 つで済む |
| 対象リポジトリ | **private + public** | Unity 開発は非公開が多い |
| PR 内表示 | **インライン置換 ＋ `[Raw\|Semantic]` トグル** | レビューの流れを崩さない |
| 認証 | **PAT のみ（プロバイダ層で抽象化）／ baseURL 設定あり** | 最小実装。github.com/GHEC/GHES を無設定でカバー。将来 OAuth を差し込める |
| 描画 | **Shadow DOM ツリービュー** | GitHub の CSS と相互非干渉 |
| WASM 実行 | **Web Worker に隔離** | メインスレッドのジャンクゼロ |

---

## 4. アーキテクチャ

### 4.1 コンポーネント図

```
┌─────────────────────────────────────────────────────────────┐
│  Chrome Extension (Manifest V3) — すべてユーザーのブラウザ内    │
│                                                             │
│  ┌───────────────┐   postMessage   ┌──────────────────────┐ │
│  │ Content Script │◀───────────────▶│ Web Worker           │ │
│  │ (TS)           │  transferable   │  ┌─────────────────┐ │ │
│  │ ・ファイル検出   │  ArrayBuffer    │  │ Zig コア (WASM) │ │ │
│  │ ・トグル注入     │                 │  │ parse/match/diff │ │ │
│  │ ・Renderer 呼出  │                 │  └─────────────────┘ │ │
│  └───────┬────────┘                 └──────────────────────┘ │
│          │ message                                          │
│  ┌───────▼────────┐    GitHub API    ┌──────────────────────┐│
│  │ Service Worker │◀────────────────▶│ chrome.storage       ││
│  │ (background TS)│   (認証付 fetch)  │ ・PAT                ││
│  │ ・PAT 管理      │                  │ ・guid→path キャッシュ││
│  │ ・blob/.meta取得 │                  └──────────────────────┘│
│  │ ・guid 解決      │                                          │
│  └────────────────┘                                          │
│  ┌────────────────┐                                          │
│  │ Options/Popup  │ PAT 入力・baseURL・テーマ・既定ビュー設定   │
│  └────────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
                     ▲
                     │ DOM 注入 / GitHub REST API（CORS 許可済）
            ┌────────┴─────────┐
            │ github.com (PR)   │
            └───────────────────┘
```

> 注: MV3 の "Service Worker" は拡張機能のバックグラウンド・スクリプトであり、**ユーザーのブラウザ内で動く**。Web のバックエンドサーバではない。本ツールに運用サーバは存在しない。

### 4.2 各コンポーネントの責務

| コンポーネント | 何をするか | 依存 |
|---|---|---|
| Content Script (TS) | Unity アセット検出、`[Raw\|Semantic]` トグル注入、Worker へ解析依頼、Renderer 呼出 | DOM, Worker, background |
| Web Worker (TS 薄) | WASM ロード、バイト列を Zig に渡し構造化 diff を返す。メインスレッド隔離 | WASM |
| Zig コア (WASM) | 前後 2 版をパース→fileID 突合→構造 diff→組み込み型/ローカル参照を内部解決→構造化 diff(JSON) | なし（純関数） |
| Service Worker (background TS) | PAT で GitHub 認証、blob(前後)・`.meta` 取得、guid→path 解決、キャッシュ | GitHub API, chrome.storage |
| Renderer (TS) | 構造化 diff ＋ guid→path 表 → Shadow DOM ツリー。トグル・折りたたみ・テーマ | DOM |
| Options/Popup (TS) | PAT 入力、baseURL、設定 | chrome.storage |

### 4.3 データフロー（トグル ON 時）

```
1. PR「Files changed」を開く
2. Content Script: パスが *.prefab/*.unity/*.asset に一致 → ファイル頭にトグル注入
3. (ユーザーが Semantic 選択 or 既定で自動)
4. Content → background: 当該ファイルの前後 blob 要求
5. background → GitHub API: base SHA / head SHA の blob 取得（PAT 認証付）
6. Content → Worker: 前後バイト列を transferable で渡す（ゼロコピー）
7. Worker → Zig(WASM): diff(before, after)
     Zig 内部で解決:
       ・!u!114 → "MonoBehaviour"（静的 classID テーブル）
       ・{fileID:12345}（guid 無し）→ 同一ファイル内の対象に突合
     外部解決が要るものは「未解決 guid 集合」として併せて返す
8. Worker → Content: 構造化 diff JSON ＋ 未解決 guid 集合
9. Content → background: guid 集合の解決依頼
     → ①PR 変更 .meta ②コード検索 `"<guid>" path:*.meta` ③キャッシュ
     → guid→path 表（repo + head SHA でキャッシュ）
10. Renderer: 構造化 diff を描画、スクリプト名は guid→path 表で解決
    GitHub の生 diff を隠し、トグルで相互切替
```

---

## 5. Zig コア設計

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

- 汎用 YAML ライブラリは使わず、**Unity YAML 限定サブセット専用の一発パス・パーサ**を自作する。
  - ブロックスタイル中心、flow は `{fileID:..}` 等の埋め込みのみ、2 スペース固定インデント、エイリアスはドキュメントの `&fileID` のみ。
- インデントスタックでドキュメント群を生成。`{fileID:.., guid:.., type:..}` は Ref ノードとして特別認識。
- malformed 入力に対して堅牢（フォールバックのためエラーを返す）。

### 5.4 名前解決の 3 分岐

| 参照の種類 | 例 | 解決方法 | ネットワーク |
|---|---|---|---|
| 組み込み classID | `!u!1`, `!u!4`, `!u!114` | Zig 内蔵の静的 classID テーブル → 型名 | 不要 |
| ローカル参照 | `{fileID: 234}` | 同一ファイル内の同 anchor ドキュメントへ突合 | 不要 |
| 外部参照(guid) | `{fileID:.., guid:.., type:3}` | Zig は不能 → 未解決 guid 集合として出力、TS が解決 | 必要（少数） |

### 5.5 diff アルゴリズム

```
1. 前後それぞれをパース → Document 群
2. GameObject 階層を再構築（Transform.m_Father/m_Children, m_Component で紐付け）
3. オブジェクトを fileID で突合（前後マッチング）
4. マッチした各オブジェクト → 本体マッピングを再帰的フィールド diff
5. 分類: Added / Removed / Modified / Unchanged
6. GameObject 階層を反映した差分ツリーを生成（Unchanged は畳む）
```

- **突合キー = fileID**。Unity は編集をまたいで安定した fileID を振るため、行位置でなくオブジェクトの同一性で前後対応できる。これが「コンポーネント追加で複数行がズレる」問題に惑わされない根拠。
- 例外（fileID が変わる稀ケース）には二次マッチ `(型 + m_Name + 親)` の類似度で救済。**v1 は fileID 主・名前フォールバックは v1.1 以降**でも可。
- フィールド diff は参照を「解決後のアイデンティティ」で比較（ローカル=対象 fileID、外部=guid+fileID）。値の前後・追加キー・削除キー・参照の張り替えを区別。

### 5.6 WASM ABI / メモリ

- エクスポート: `alloc(len)`, `free(ptr,len)`, `diff(before*, beforeLen, after*, afterLen) -> resultPtr`（長さ前置の JSON バイト列）。
- diff 1 回 = 1 arena、呼出ごとにリセット。グローバル状態なし＝**純関数**でテスト容易・再入可能。
- 出力は v1 では **JSON**（差分のみで小さく、境界コストは無視可）。必要ならコンパクトバイナリへ差替可能。

### 5.7 性能目標（CI で強制）

| 指標 | 目標 |
|---|---|
| WASM バンドル(gzip) | ≤ 80 KB（上限 150 KB） |
| 典型 prefab(≤200KB) の parse+diff | < 5 ms |
| 巨大 scene(~10MB) の parse+diff | < 150 ms |
| ピークメモリ | input の約 3 倍以内 |
| メインスレッド | Web Worker 隔離＝ジャンクゼロ |
| トグル→描画(ネット除く) | < 300 ms |
| 巨大ファイルガード | 25MB 超は「クリックで描画」に切替 |

---

## 6. TypeScript 拡張設計

### 6.1 Renderer

- 入力: 構造化 diff JSON ＋ guid→path 表 → GitHub のファイル枠に注入する DOM。
- **GameObject 階層を反映したツリービュー**。状態色（追加=緑/削除=赤/変更=黄、GitHub 配色準拠＋アクセシブル）。Modified コンポーネントはフィールド変更（旧→新）を展開。折りたたみ可。
- スクリプト名は guid→path 表で解決。未解決は短縮 guid ＋「unresolved」バッジ。
- **Shadow DOM で隔離**注入。light/dark は GitHub テーマを読み CSS 変数で追従。

### 6.2 GitHub 統合

- **検出**: Files changed 内で `*.prefab` / `*.unity` / `*.asset` のファイル枠を特定。GitHub が畳んでいるケースも考慮。
- **注入の堅牢性**: GitHub は SPA・遅延ロード（スクロールで順次描画、PJAX/turbo 遷移）。`MutationObserver` で動的再注入、セレクタは防御的に。
- **blob 取得**: PR の base/head SHA から前後内容を取得（Contents API か Git Blobs API）。追加/削除は片側空。
- **guid 解決の 3 段**: ①PR 自身の変更 `.meta`（PR 内追加の新規スクリプトを拾う）→ ②コード検索 `"<guid>" path:*.meta`（既存）→ ③`repo+sha` でキャッシュ → ④未解決はフォールバック。

### 6.3 認証

- **PAT のみ**。`chrome.storage` に保存。`getToken()` を返す**プロバイダ層**の裏に置き、将来 OAuth Device Flow / GitHub App を差し込めるようにする。
- **baseURL 設定**で github.com / GHEC / GHES をカバー（GHES はユーザーが自インスタンスで PAT 作成→貼付で無設定動作）。

### 6.4 エラー処理 / エッジケース（原則: ページを壊さない）

| ケース | 挙動 |
|---|---|
| パース失敗・想定外形式 | 生 diff にフォールバック＋小さな注意表示 |
| 巨大ファイル(>25MB) | 「クリックで描画」ガード |
| 追加/削除/リネーム | 片側 diff として処理 |
| guid 未解決（外部パッケージ等） | 短縮 guid ＋バッジ |
| レート制限(403/429)・認証失敗(401) | 設定（PAT 追加/更新）への導線 |
| バイナリ `.asset` | YAML ヘッダ検出、非 YAML はスキップ |
| GitHub の DOM 変更 | try/catch で安全側、生 diff を残す。console にログ |
| WASM ロード失敗 | 生 diff にフォールバック |

---

## 7. テスト戦略

- **Zig コア**: `std.testing` でパーサ＋diff の単体テスト。フィクスチャ群（追加/削除コンポーネント、reparent、ネスト prefab、巨大 scene、fileID 衝突）。diff 出力のゴールデンファイル比較。malformed 入力のファジング。
- **WASM 境界**: コンパイル済 WASM を Node で実行しフィクスチャ→JSON 出力をゴールデン照合。
- **TS 単体**: GitHub API クライアント（fetch モック）、guid 解決＋キャッシュ、レンダラの DOM スナップショット。
- **E2E**: Playwright で保存済み PR ページ HTML に対し、検出→トグル注入→描画→Raw/Semantic 切替を検証。
- **CI**: GitHub Actions で Zig→WASM ビルド／Zig テスト／Node WASM テスト／TS・Playwright／WASM バンドルサイズ予算チェック（上限超で失敗）。

---

## 8. プロジェクト構成（モノレポ）

```
/core        ← Zig: parser, model, diff, WASM exports
  build.zig
  src/
  tests/fixtures/
/extension   ← TS(MV3)
  src/content/   (検出・注入・オーケストレーション)
  src/worker/    (WASM ローダ)
  src/background/(PAT・GitHub API・guid 解決・キャッシュ)
  src/renderer/  (Shadow DOM ツリービュー)
  src/options/   (PAT 入力・設定)
  manifest.json
/docs
```

---

## 9. スコープ

### 9.1 v1 に入れる

- prefab/scene/asset の L2 意味的 diff
- Zig WASM コア（fileID 突合・フィールド diff・静的 classID テーブル・ローカル参照解決）
- TS 拡張（検出・インライン `[Raw|Semantic]` トグル・Shadow DOM ツリーレンダラ）
- GitHub PR「Files changed」面
- PAT 認証（プロバイダ層で抽象化）・baseURL 設定（github.com/GHEC/GHES）
- guid 解決（PR 変更 meta ＋コード検索＋キャッシュ）
- Chrome (MV3)・CI で性能予算を強制

### 9.2 v1 に入れない（後追い）

- L3 ビジュアル描画
- OAuth Device Flow / GitHub App 認証
- Firefox / Edge 移植
- Unity Editor 統合・CI/CLI 版
- 意味ノードに紐づく PR レビューコメント
- マージ衝突解決
- commit 比較・blob 単体ビューの面（v1 は PR Files changed のみ）
- 名前ベースの二次マッチング（v1 は fileID 主）

> v1 から外したものの多くは「面の追加」と「認証方式の追加」であり、Zig の diff エンジン（コア）に手を入れずに足せる。v1 の投資は無駄にならない。

---

## 10. リスク / 未解決事項

| リスク | 緩和策 |
|---|---|
| GitHub UI 変更で注入が壊れる | 防御的セレクタ・try/catch・生 diff フォールバック。E2E で早期検知 |
| コード検索 API のレート制限・インデックス遅延（既定ブランチのみ等） | PR 変更 meta を先に使う／キャッシュ／未解決フォールバック |
| Zig pre-1.0 の破壊的変更 | Zig バージョンを固定（`build.zig.zon`）。CI で追従 |
| 巨大 scene の相互参照・ネスト prefab の複雑さ | フィクスチャに含めて段階対応。v1 は fileID 突合を堅実に |
| fileID が変わるケースで誤マッチ | v1 は fileID 主、二次マッチは後続で追加 |
