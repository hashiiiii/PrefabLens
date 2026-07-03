# PrefabLens フェーズ2（Chrome 拡張ホスト）設計 — ウォーキングスケルトン

> **ステータス:** 承認済み（2026-07-03）。実装計画: `docs/superpowers/plans/2026-07-03-prefablens-phase2-chrome-extension.md`
>
> **前提:** 上位仕様 `docs/superpowers/specs/2026-06-29-unity-prefab-diff-design.md` の §5.6（コア ABI）・§5.7（性能）・§6.2（Chrome ホスト）・§7（テスト）・§8（構成）・§9（Phase 2 スコープ）を親仕様とする。本書はその Phase 2 を **シンプルさ最優先のウォーキングスケルトン** として具体化したもの。矛盾する場合は本書のスコープ判断（初回に何を入れ/延期するか）が優先し、アーキテクチャの型は親仕様に従う。

## 目標

GitHub の PR「Files changed」画面で、Unity の `.prefab` / `.unity` / `.asset`（YAML）の変更を **意味的 diff** としてインライン表示する Chrome 拡張（MV3）を出す。フェーズ1で完成した純粋 Zig の core を **WASM 化して再利用** し、バックエンド無し・運用費ゼロで動かす。

初回は「一番細いが端から端まで通るパイプライン」を最小コードで実装する。検出 → blob 取得 → WASM diff → guid 解決 → Shadow DOM 描画の各接合部（特に WASM 境界と Shadow DOM 注入）が最大のリスクであり、そこを先に潰す。

## スコープ

### 初回に入れる

- PR「Files changed」内で `.prefab` / `.unity` / `.asset` を検出（`MutationObserver` で GitHub の SPA・遅延ロードに追従、セレクタは防御的に）。**面は PR Files changed のみ**（commit 比較・blob 単体ビューは対象外）。
- インライン `[Raw | Semantic]` トグル。Raw = GitHub 既定の diff、Semantic = 本拡張の意味的 diff。
- base/head の blob 内容を GitHub API（Contents/Blobs）で取得。追加/削除は片側空。
- WASM（Web Worker 上）で core の `diff()` を呼び、`prefablens.diff.v1` JSON を得る。
- guid 解決は **同じ PR 内で変更された `.meta` のみ**（PR 変更ファイル一覧から `.meta` を集めて guid→path 索引を構築）。
- Shadow DOM ツリーレンダラ（GitHub の CSS と非干渉、light/dark 追従）。
- Options ページ：PAT 入力・baseURL 設定（github.com / GHEC / GHES）。
- CI に **WASM gzip バンドルサイズ予算チェック**（≤ 80 KB、上限 150 KB 超で失敗）。

### 初回は延期（follow-up）

- **Code Search API による guid 解決**（`"<guid>" path:*.meta`）。レート制限・非同期・キャッシュ設計が重いため。
- **`repo + sha` キャッシュ**。
- **25 MB 超のクリック描画ガード**（性能目標 §5.7 の巨大ファイル対策）。
- **Playwright E2E の本格整備**（初回は最小スモーク1本のみ）。
- commit 比較・blob 単体ビュー面、OAuth、Firefox/Edge 移植。

> 延期項目は「入れない」ではなく「初回スコープ外」。設計上の差し込み口（guid リゾルバのプロバイダ層、キャッシュ層の空きフック）は初回から用意し、後続で無改造に近い形で足せるようにする。

## アーキテクチャ

親仕様 §6.2 の構成をそのまま踏襲する。各モジュールは責務を1つだけ持ち、明確なインターフェースで通信し、独立してテストできる。

```
GitHub PR page (github.com / GHES / GHEC)
  │
  ├─ content/     検出・トグル注入・オーケストレーション（isolated world）
  │     │  ├─→ background/  (PAT・GitHub API・guid 解決)
  │     │  └─→ worker/      (WASM diff)
  │     └─→ renderer/       (Shadow DOM ツリー)
  ├─ background/  Service Worker: PAT 取得・GitHub API・guid→path 索引
  ├─ worker/      Web Worker: WASM ロード + diff() 呼出（メインスレッド隔離）
  ├─ renderer/    prefablens.diff.v1 JSON → Shadow DOM
  └─ options/     PAT 入力・baseURL 設定
```

| モジュール | 責務 | 使い方（インターフェース） | 依存 |
|---|---|---|---|
| `content/` | Files changed の Unity ファイル検出、`[Raw\|Semantic]` トグル注入、パイプラインのオーケストレーション | DOM に注入される content script。検出した各ファイルについて background から前後内容と guid 索引を取り、worker で diff し、renderer に渡す | DOM API、`worker`、`background`（`chrome.runtime` メッセージ） |
| `worker/` | WASM をロードし `diff(before, after)` を呼び、`prefablens.diff.v1` JSON を返す | `postMessage({before, after})` → `{json}`。メインスレッドから隔離 | `.wasm`（core） |
| `background/` | PAT を `getToken()` プロバイダ層の裏で管理、GitHub API 呼出（blob 取得・PR 変更ファイル一覧）、PR 内 `.meta` から guid→path 索引を構築 | `chrome.runtime` メッセージハンドラ。`{type:'blobs', owner, repo, base, head, path}` → `{before, after}`、`{type:'guidIndex', owner, repo, sha}` → `{map}` | `chrome.storage`、GitHub REST API |
| `renderer/` | `prefablens.diff.v1` JSON（`resolved` 付与済み）を Shadow DOM ツリーに描画。GitHub の CSS と非干渉、light/dark 追従 | `render(shadowRoot, diffJson)` の純関数的 DOM 構築 | なし（DOM のみ） |
| `options/` | PAT 入力・baseURL 設定 | Options ページ。`chrome.storage` に保存 | `chrome.storage` |

### 責務分離の根拠

- **PAT は background に閉じる。** content script（isolated world）や worker に PAT を渡さない。認証付き fetch は background Service Worker で行い、トークンの取り回しを一元化し、ページの CSP の影響を避ける。`getToken()` プロバイダ層の裏に置くことで将来 OAuth を差し込める。
- **WASM は Web Worker に隔離。** メインスレッドのジャンクをゼロにする（性能目標 §5.7）。WASM の入出力はバイト列と長さ前置 JSON のみで、UI から切り離す。
- **guid 解決は content 側で JSON に適用。** core（WASM）は `unresolvedGuids` を返すだけの純関数を保ち（仕様 §4.2 のシーム）、ホスト（拡張）が索引で `resolved` を付与する。フェーズ1 CLI と同じ設計で、core の純粋性・再利用性を崩さない。

## データフロー

1. content が PR ページで Unity ファイルの diff コンテナを検出し、各ファイルの見出しに `[Raw | Semantic]` トグルを注入する。既定は Raw（GitHub 既定表示のまま）。
2. ユーザーが Semantic を選ぶと、content が該当ファイルの `{owner, repo, base SHA, head SHA, path}` を background に送る。
3. background が PAT で GitHub API から base/head の blob を取得する（追加/削除は片側空）。並行して、PR 変更ファイル一覧（既に content が持つ、または API 取得）から `.meta` を集め、guid→path 索引を構築する。
4. content が before/after バイト列を worker に渡し、worker が WASM `diff()` を呼んで `prefablens.diff.v1` JSON を返す。
5. content が JSON の `unresolvedGuids` を索引で解決し、`resolved` を付与する（未解決は生 guid のまま）。
6. renderer が JSON を Shadow DOM ツリーに描画し、Raw ビューの位置にインライン挿入する。再トグルで Raw に戻せる。

## WASM とビルド

### core の WASM ターゲット

- `build.zig` に **freestanding-wasm ライブラリターゲット** を追加する。フェーズ1の core（`core/src/root.zig`）を再コンパイルし、親仕様 §5.6 の C ABI をエクスポートする：
  - `alloc(len) -> ptr`
  - `free(ptr, len)`
  - `diff(before_ptr, before_len, after_ptr, after_len) -> result_ptr`（`result_ptr` は長さ前置の `prefablens.diff.v1` JSON バイト列を指す）
- バンプアロケータを使い、diff 1 回 = 1 arena、呼出ごとにリセット。グローバル可変状態なし＝純関数で再入可能。core は既にこの前提（アリーナ確保・ゼロコピー）で書かれており、ロジックの変更は不要。ABI の薄いラッパ（`core/src/wasm.zig` 相当）を足すだけ。
- core のロジック（parser/diff/tree/json）は WASM/ネイティブで同一ソース。ターゲット違いのみ。

### 拡張のビルドツール

- **esbuild** を採用する。MV3 の複数エントリ（`content` / `worker` / `background` / `options`）を最小設定でバンドルできる。Vite + CRXJS は DX は良いが重く、シンプルさ最優先なら esbuild が適切。
- 拡張のビルドが core ビルド成果物の `.wasm` を取り込む（`extension/` 配下へコピー、または import）。
- TypeScript（`tsc` で型チェック、esbuild でバンドル）。

### サイズ予算

- CI で **WASM gzip サイズ** を計測し、≤ 80 KB（上限 150 KB 超で失敗）をゲートする。フェーズ1の perf ゲートと同じ「予算超過で CI 失敗」の型。

## エラー処理

フェーズ1で確立した「クリーンな 1 行メッセージ、raw を漏らさない」方針を Chrome でも踏襲する。

- **PAT 未設定 / 401**：トグル横に Shadow DOM で「Options で PAT を設定してください」を表示。コンソールにトークンや raw エラーを漏らさない。
- **blob 取得失敗**：該当ファイルのみエラー表示、他ファイルの表示は継続。
- **WASM エラー（`NestingTooDeep` 等）**：握りつぶさず「差分を表示できません」を表示。
- **guid 未解決**：生 guid のまま表示（フォールバック）。
- **検出失敗 / セレクタ変化**：防御的セレクタで無害に何もしない（ページを壊さない）。

## テスト戦略

親仕様 §7 に従い、初回は最小だが実挙動を検証する。

- **WASM 境界**：コンパイル済 WASM を Node で実行し、`prefablens.diff.v1` JSON をゴールデン照合。フェーズ1の core ゴールデンを再利用し、WASM 経由でも同一出力になることを確認。
- **TS 単体**：
  - GitHub API クライアント（`fetch` モックで blob 取得・PR 変更ファイル一覧）。
  - guid 解決（PR 内 `.meta` からの索引構築と `resolved` 付与）。
  - renderer の DOM スナップショット（Shadow DOM ツリー構造）。
- **E2E（Playwright）**：初回は最小スモーク1本のみ（保存済み PR ページ HTML に対し 検出 → トグル → 描画）。本格整備は follow-up。
- **CI**：GitHub Actions に Zig→WASM ビルド／Node WASM ゴールデン／TS 単体／WASM サイズ予算チェックを追加（既存の test + perf ジョブと並列）。

## ファイル構成

親仕様 §8 の `/extension` を具体化する。

```
/core
  src/
    wasm.zig            # WASM C ABI ラッパ（alloc/free/diff）。core ロジックは無改造で再利用
/extension              # TS(MV3) Chrome ホスト
  src/
    content/            # 検出・トグル注入・オーケストレーション
    worker/             # WASM ロード + diff 呼出（Web Worker）
    background/          # Service Worker: PAT・GitHub API・guid 解決
    renderer/           # Shadow DOM ツリー
    options/            # PAT 入力・baseURL 設定
    github/             # GitHub API クライアント + getToken() プロバイダ層
  manifest.json         # MV3
  build.mjs             # esbuild ビルドスクリプト（複数エントリ + .wasm 取り込み）
  package.json
/build.zig              # WASM lib ターゲットを追加
```

## 未解決事項（実装計画で詰める）

- GitHub REST API の具体的エンドポイントと最小 host_permissions（Contents/Blobs、PR files 一覧）。
- Web Worker への WASM ロード方法（`fetch` + `WebAssembly.instantiate`、または import）と MV3 の制約（`web_accessible_resources` で `.wasm` を公開する必要の有無）。
- Shadow DOM の light/dark 追従の具体手段（GitHub の `data-color-mode` 追随）。
- baseURL 設定時の API ベース（`https://api.github.com` vs GHES の `<host>/api/v3`）の切替。
