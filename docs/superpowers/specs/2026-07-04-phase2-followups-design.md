# PrefabLens Phase 2 follow-ups 設計 — GHES 実体化・guid 解決強化・巨大ファイルガード・E2E 本格化

- **日付**: 2026-07-04
- **ステータス**: 承認済み(ユーザー承認 2026-07-04)
- **親仕様**: `2026-06-29-unity-prefab-diff-design.md` §5.7・§6.2、`2026-07-03-prefablens-phase2-chrome-design.md` の延期リスト

Phase 2 初回スコープで延期した 4 項目を実体化する。設計上の差し込み口(guid リゾルバの seam、handler のコンテキストキャッシュ)は初回から用意済みで、本 follow-up はそこに実装を差し込む。

## A1. GHES サポート実体化

**問題**: `manifest.json` の `host_permissions` が `api.github.com`、`content_scripts.matches` が `github.com` 固定のため、Options の baseUrl 設定が GHES では実質機能しない(content script が注入されず、API fetch も権限がない)。

**設計**:

- manifest に `"optional_host_permissions": ["https://*/*"]` と `"scripting"` permission を追加。
- Options の Save クリック(user gesture 内)で、baseUrl が github.com 以外なら `chrome.permissions.request({ origins: [origin + "/*", apiOrigin + "/*"] })` を要求。
- 許可されたら `chrome.scripting.registerContentScripts()` で `content.js` をそのオリジンへ動的登録。登録 id は固定(`prefablens-ghes`)とし、baseUrl 変更時は旧登録を `unregisterContentScripts` してから登録し直す。動的登録は `persistAcrossSessions` 既定 true なので起動時の再登録処理は不要。
- 拒否されたら status に `Permission declined` を表示し、登録しない(保存自体は行う)。
- github.com に戻した場合は `prefablens-ghes` 登録を解除するだけ。

**テスト**: options の jsdom テストに fake `chrome.permissions` / `chrome.scripting` を渡し、要求 origin の組み立て・登録/解除・拒否時の表示を検証。origin 組み立ては純関数に切り出す。

## A2. Code Search guid 解決 + キャッシュ

**問題**: guid 解決が「PR 内で変更された `.meta`」のみで、PR 外アセット参照は unresolved のまま。

**設計**(親仕様 §6.2 の ②③):

- handler で diff 計算・PR 内 index 適用後に残った `unresolvedGuids` を Code Search API で解決する:
  `GET /search/code?q="<guid>"+repo:<owner>/<repo>+path:*.meta`。ヒットの `path` から `.meta` を剥いだものが asset path。
- **上限 1 リクエスト 10 guid・逐次実行**。Code Search はレート制限が厳しい(認証済みで 10 req/min)ため、`RateLimitError` が出たら打ち切り、解決済み分だけ適用する。**Code Search の失敗で diff 全体は落とさない**(未解決 guid はレンダラの既存フォールバック表示)。
- **guid→path キャッシュ**: `chrome.storage.local` にオリジン+repo 単位(`guids:<apiBase>/<owner>/<repo>`)で永続保存。guid→path は安定なので TTL なし。負結果(見つからず)は SW 生存期間の in-memory のみ(インデックス遅延があるため永続化しない)。
- **制約(仕様通り)**: Code Search API はデフォルトブランチのみを索引するため、解決結果は「現在のデフォルトブランチ上の対応」。PR 固有の移動には PR 内 `.meta` 索引(既存)が先勝ちする。

**PR コンテキストの鮮度**: 既存の PR 単位コンテキストキャッシュ(SW 生存期間)に **60 秒 TTL** を付け、push 後の headSha 変化に追従する。blob は `sha+path` キーの in-memory キャッシュ(内容は不変なので TTL 不要)。

## A3. 25MB クリック描画ガード

親仕様 §5.7「25MB 超は『クリックで描画』」の実装。

- handler は blob 取得後、`before.length + after.length > 25 * 1024 * 1024` かつ `req.force !== true` なら `{ ok: false, error: "too-large", bytes }` を返す(diff 計算しない)。
- content は `too-large` に対し「Large file (NN MB) — click to render」ボタンを表示し、クリックで `force: true` を付けて再要求。blob は A2 の sha キャッシュにより再フェッチされない。

## A4. Playwright E2E 本格整備

- 既存のスタブ版 2 本(content script 単体 + canned background)は維持。
- **full-stack E2E を追加**: `launchPersistentContext` + `--load-extension` で本物の拡張をロードし、ローカル HTTP サーバに (a) PR ページ fixture、(b) canned GitHub API 応答(`/api/v3/...`)を置く。Options でそのオリジンを baseUrl に設定 → A1 の動的登録がそのオリジンを「GHES」として登録 → 検出 → 実 background(実 fetch)→ 実 WASM diff → Shadow DOM 描画までを端から端まで検証する。A1 の GHES 経路の実機検証を兼ねる。
- 25MB ガードのクリック描画も full-stack で 1 ケース検証(canned 応答で 25MB 超を返すのはメモリ節約のため `content-length` 偽装ではなく実サイズの疎データで行う)。

## PR 分割と運用

| PR | 内容 | マージ |
|---|---|---|
| 1 | spec/plan doc + A1 GHES 実体化 | レビュー指摘の後始末につき CI green で自己マージ可 |
| 2 | A2 guid 解決強化 + キャッシュ + A3 ガード | 機能本体につき PR 作成まででユーザー確認 |
| 3 | A4 E2E 本格整備 | polish につき CI green で自己マージ可 |

## スコープ外

- OAuth、Firefox/Edge 移植、commit 比較・blob 単体ビュー面(親仕様の延期リストのまま)
- `numEql` の epsilon 化(2026-07-04 ユーザー判断で見送り確定)
