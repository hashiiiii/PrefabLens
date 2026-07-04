# Phase 2 Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 2 で延期した 4 項目(GHES 実体化・Code Search guid 解決+キャッシュ・25MB ガード・full-stack E2E)を 3 本の PR で実装する。

**Architecture:** 既存の seam(guid リゾルバ・handler のコンテキストキャッシュ・Deps 注入)に差し込む。新しい層は作らない。spec: `docs/superpowers/specs/2026-07-04-phase2-followups-design.md`。

**Tech Stack:** TS (MV3) + vitest + jsdom + Playwright。コア(Zig/WASM)は無改造。

## Global Constraints

- コミットは 1 行英語 `<type>: <subject>` ≤50 字(git-conventions)
- 実装は最小限・直接的に(coding-preferences)。テストは網羅的でよい
- Chrome の match pattern にポートは書けない(ポートなしパターンは全ポートに一致)
- Code Search API は legacy 構文(`extension:meta`)・デフォルトブランチのみ索引・認証済み 10 req/min
- 検証コマンド: `npm run typecheck && npm test`(extension/)、E2E は `npm run e2e`

---

## PR 1 — `fix/ghes-host-registration`(自己マージ可)

### Task 1: originOf の切り出しと ghesOrigins / applyGhes

**Files:**
- Modify: `extension/src/github/client.ts`(apiBase のオリジン計算を `originOf` として export)
- Create: `extension/src/options/ghes.ts`
- Test: `extension/src/options/ghes.test.ts`

**Interfaces:**
- Produces: `originOf(baseUrl: string): string` / `ghesOrigins(baseUrl: string): string[] | null` / `applyGhes(baseUrl: string, c: ChromeGhes): Promise<'ok' | 'declined'>` / `type ChromeGhes`

- [ ] **Step 1: 失敗するテストを書く** — `ghes.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { applyGhes, ghesOrigins, type ChromeGhes } from './ghes';

function fakeChrome(granted = true) {
  return {
    permissions: { request: vi.fn(async () => granted) },
    scripting: {
      registerContentScripts: vi.fn(async () => {}),
      unregisterContentScripts: vi.fn(async () => {}),
    },
  } satisfies ChromeGhes;
}

describe('ghesOrigins', () => {
  it('returns null for github.com and empty', () => {
    expect(ghesOrigins('')).toBeNull();
    expect(ghesOrigins('github.com')).toBeNull();
    expect(ghesOrigins('https://github.com')).toBeNull();
  });
  it('builds a port-less match pattern', () => {
    expect(ghesOrigins('ghe.corp.com')).toEqual(['https://ghe.corp.com/*']);
    expect(ghesOrigins('http://127.0.0.1:8080')).toEqual(['http://127.0.0.1/*']);
  });
});

describe('applyGhes', () => {
  it('unregisters stale registration then registers the GHES origin', async () => {
    const c = fakeChrome();
    expect(await applyGhes('ghe.corp.com', c)).toBe('ok');
    expect(c.scripting.unregisterContentScripts).toHaveBeenCalledWith({ ids: ['prefablens-ghes'] });
    expect(c.scripting.registerContentScripts).toHaveBeenCalledWith([
      { id: 'prefablens-ghes', matches: ['https://ghe.corp.com/*'], js: ['content.js'], runAt: 'document_idle' },
    ]);
  });
  it('only clears registration for github.com', async () => {
    const c = fakeChrome();
    expect(await applyGhes('', c)).toBe('ok');
    expect(c.permissions.request).not.toHaveBeenCalled();
    expect(c.scripting.registerContentScripts).not.toHaveBeenCalled();
  });
  it('returns declined without registering when permission is denied', async () => {
    const c = fakeChrome(false);
    expect(await applyGhes('ghe.corp.com', c)).toBe('declined');
    expect(c.scripting.registerContentScripts).not.toHaveBeenCalled();
  });
  it('survives unregister rejection (no stale registration)', async () => {
    const c = fakeChrome();
    c.scripting.unregisterContentScripts.mockRejectedValue(new Error('no such id'));
    expect(await applyGhes('ghe.corp.com', c)).toBe('ok');
  });
});
```

- [ ] **Step 2: 失敗確認** — `npm test` → ghes.ts が無く FAIL
- [ ] **Step 3: 実装** — `client.ts` に:

```ts
export function originOf(baseUrl: string): string {
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(baseUrl) ? baseUrl : `https://${baseUrl}`;
  return new URL(withScheme).origin;
}
```

(apiBase は originOf を使う形に整理)。`ghes.ts`:

```ts
import { originOf } from '../github/client';

export type ChromeGhes = {
  permissions: { request(p: { origins: string[] }): Promise<boolean> };
  scripting: {
    registerContentScripts(s: object[]): Promise<void>;
    unregisterContentScripts(f: { ids: string[] }): Promise<void>;
  };
};

const ID = 'prefablens-ghes';

/** baseUrl が GHES を指すときの content script 注入対象。match pattern はポート不可(ポートなしは全ポート一致)。 */
export function ghesOrigins(baseUrl: string): string[] | null {
  if (!baseUrl) return null;
  const origin = originOf(baseUrl);
  if (origin === 'https://github.com') return null;
  const u = new URL(origin);
  return [`${u.protocol}//${u.hostname}/*`];
}

/** Save クリック(user gesture)内で呼ぶ: 権限要求 → content script 動的登録。登録は永続。 */
export async function applyGhes(baseUrl: string, c: ChromeGhes): Promise<'ok' | 'declined'> {
  await c.scripting.unregisterContentScripts({ ids: [ID] }).catch(() => {}); // 未登録なら reject する
  const origins = ghesOrigins(baseUrl);
  if (!origins) return 'ok';
  if (!(await c.permissions.request({ origins }))) return 'declined';
  await c.scripting.registerContentScripts([{ id: ID, matches: origins, js: ['content.js'], runAt: 'document_idle' }]);
  return 'ok';
}
```

- [ ] **Step 4: PASS 確認** — `npm run typecheck && npm test`
- [ ] **Step 5: Commit** — `feat: add ghes origin grant and script registration`

### Task 2: manifest + options 配線

**Files:**
- Modify: `extension/manifest.json`(`"permissions": ["storage", "scripting"]`、`"optional_host_permissions": ["https://*/*", "http://127.0.0.1/*"]`)
- Modify: `extension/src/options/options.ts` / Test: `extension/src/options/options.test.ts`

**Interfaces:**
- Consumes: `applyGhes` / `ChromeGhes`(Task 1)
- Produces: `initOptions(doc, storage, ghes?: ChromeGhes)` — ghes 未指定時は登録をスキップ(既存テスト互換)

- [ ] **Step 1: 失敗するテストを追加** — options.test.ts に: Save 成功+GHES 許可 → `Saved`、拒否 → `Saved (host permission declined)`、applyGhes が baseUrl のトリム済み値で呼ばれること
- [ ] **Step 2: FAIL 確認**
- [ ] **Step 3: 実装** — save クリックで `applyGhes` を先に(gesture 内)、次に `storage.set`。宣言的に:

```ts
doc.querySelector<HTMLButtonElement>('#save')!.addEventListener('click', () => {
  void (async () => {
    const grant = ghes ? await applyGhes(baseUrl.value.trim(), ghes) : 'ok';
    await storage.set({ pat: pat.value.trim(), baseUrl: baseUrl.value.trim() });
    status.textContent = grant === 'declined' ? 'Saved (host permission declined)' : 'Saved';
  })().catch(() => {
    status.textContent = 'Save failed';
  });
});
```

エントリ(`chrome.storage` ガード内)は `initOptions(document, chrome.storage.local, chrome)` を渡す。

- [ ] **Step 4: PASS 確認** — `npm run typecheck && npm test && npm run build && npm run e2e`
- [ ] **Step 5: Commit** — `fix: register ghes host so base url works`

### Task 3: PR 1 作成 → CI green → 自己マージ

- [ ] push、`gh pr create`(spec/plan doc 込み)、CI green 確認、squash 自己マージ(workflow-autonomy 通り)

---

## PR 2 — `feat/code-search-guid-resolution`(main へレビュー依頼、マージ前ユーザー確認)

### Task 4: GithubClient.searchMetaByGuid

**Files:**
- Modify: `extension/src/github/client.ts` / Test: `extension/src/github/client.test.ts`

**Interfaces:**
- Produces: `searchMetaByGuid(owner, repo, guid): Promise<string | null>` — 戻りは **asset path(.meta を剥いだもの)**、未ヒット/422 は null

- [ ] **Step 1: テスト** — fetch モックで: クエリが `"g1" repo:o/r extension:meta` を URL エンコードして含む / items[0].path から `.meta` を剥いで返す / items 空・422 → null / 403 rate limit → RateLimitError 伝播
- [ ] **Step 2: FAIL 確認** → **Step 3: 実装**:

```ts
/** Code Search(legacy 構文・デフォルトブランチのみ索引)で guid → asset path を引く。 */
async searchMetaByGuid(owner: string, repo: string, guid: string): Promise<string | null> {
  const q = encodeURIComponent(`"${guid}" repo:${owner}/${repo} extension:meta`);
  const res = await this.request(`/search/code?q=${q}&per_page=1`, 'application/vnd.github+json');
  if (!res.ok) return null; // 422(未インデックス等)は「未解決」として扱う
  const body = (await res.json()) as { items?: Array<{ path?: string }> };
  const path = body.items?.[0]?.path;
  return path?.endsWith('.meta') ? path.slice(0, -'.meta'.length) : null;
}
```

- [ ] **Step 4: PASS** → **Step 5: Commit** — `feat: add code search guid lookup to client`

### Task 5: handler の検索解決 + GuidCache + 負キャッシュ

**Files:**
- Modify: `extension/src/github/guids.ts`(`GuidCache` 型)/ `extension/src/background/handler.ts` / Test: `extension/src/background/handler.test.ts`

**Interfaces:**
- Consumes: `searchMetaByGuid`(Task 4)
- Produces: `type GuidCache = { load(repo: string): Promise<Record<string, string>>; save(repo: string, entries: Record<string, string>): Promise<void> }`、`Deps.guidCache: GuidCache`。repo キーは `${apiBase}/${owner}/${repo}`

- [ ] **Step 1: テスト** — PR 内 .meta 未解決の guid が検索で解決され `resolved` に載る / キャッシュヒットは検索しない / 未ヒット guid は同一 handler 内で再検索しない(負キャッシュ) / RateLimitError で打ち切っても diff は ok / 1 リクエスト最大 10 検索 / 解決分が `guidCache.save` される
- [ ] **Step 2: FAIL** → **Step 3: 実装** — createHandler 閉包に `const misses = new Set<string>()`。diff+applyResolved 後:

```ts
const MAX_SEARCHES = 10;

async function searchUnresolved(json: DiffV2, client: ClientLike, owner: string, repo: string, repoKey: string): Promise<DiffV2> {
  const resolved = { ...json.resolved };
  const pending = json.unresolvedGuids.filter((g) => !(g in resolved) && !misses.has(`${repoKey}:${g}`));
  if (!pending.length) return { ...json, resolved };
  const cached = await deps.guidCache.load(repoKey);
  const found: Record<string, string> = {};
  let searches = 0;
  for (const g of pending) {
    if (cached[g] !== undefined) {
      resolved[g] = cached[g];
      continue;
    }
    if (searches++ >= MAX_SEARCHES) continue;
    try {
      const path = await client.searchMetaByGuid(owner, repo, g);
      if (path) resolved[g] = found[g] = path;
      else misses.add(`${repoKey}:${g}`);
    } catch (err) {
      if (err instanceof RateLimitError) break; // 解決済み分だけで劣化継続。diff は落とさない
      misses.add(`${repoKey}:${g}`);
    }
  }
  if (Object.keys(found).length) await deps.guidCache.save(repoKey, found);
  return { ...json, resolved };
}
```

- [ ] **Step 4: PASS** → **Step 5: Commit** — `feat: resolve out-of-pr guids via code search`

### Task 6: コンテキスト TTL 60s + blob sha キャッシュ

**Files:**
- Modify: `extension/src/background/handler.ts` / Test: `extension/src/background/handler.test.ts`

- [ ] **Step 1: テスト** — `vi.setSystemTime` で 60 秒経過後に refs/files を再取得、60 秒内は再利用 / 同一 `sha:path` の blob は 1 回しか fetch されない(force 再要求の再フェッチ回避)
- [ ] **Step 2: FAIL** → **Step 3: 実装** — `contexts: Map<string, { at: number; ctx: Promise<PrContext> }>`(TTL 60_000)。blob は `Map<string, Uint8Array | null>`、キー `${sha}:${path}`、32 件で最古を追い出し
- [ ] **Step 4: PASS** → **Step 5: Commit** — `feat: add context ttl and blob sha cache`

### Task 7: 25MB クリック描画ガード(background 側)

**Files:**
- Modify: `extension/src/types.ts` / `extension/src/background/handler.ts` / Test: `extension/src/background/handler.test.ts`

**Interfaces:**
- Produces: `SemanticDiffRequest.force?: boolean`、`SemanticDiffResponse` に `{ ok: false; error: 'too-large'; bytes: number }` を追加(`BackgroundError` はそのまま)

- [ ] **Step 1: テスト** — 合計 25MB 超で `too-large`(diff は呼ばれない)/ `force: true` なら diff する / 25MB ちょうどは通る
- [ ] **Step 2: FAIL** → **Step 3: 実装** — `const TOO_LARGE = 25 * 1024 * 1024;` fetch 後に `if (!req.force && before.length + after.length > TOO_LARGE) return { ok: false, error: 'too-large', bytes: ... };`
- [ ] **Step 4: PASS** → **Step 5: Commit** — `feat: gate oversized diffs behind explicit render`

### Task 8: 25MB ガード(content/renderer 側)

**Files:**
- Modify: `extension/src/renderer/render.ts`(`renderTooLarge`)/ `extension/src/content/index.ts` / Test: `extension/src/renderer/render.test.ts`

**Interfaces:**
- Produces: `renderTooLarge(root: ShadowRoot, bytes: number, onRender: () => void): void`

- [ ] **Step 1: テスト** — renderTooLarge が MB 表示とボタンを描画し、クリックで onRender が呼ばれる
- [ ] **Step 2: FAIL** → **Step 3: 実装** — render.ts に `.pl-render` スタイル + ボタン。content は応答処理を `show(res)` に括り出し、`too-large` でボタン → クリックで `force: true` 再要求(`requested` は成功時のみ true 維持)
- [ ] **Step 4: PASS** → **Step 5: Commit** — `feat: render click-through for oversized files`

### Task 9: background 配線 + PR 2 作成

**Files:**
- Modify: `extension/src/background/index.ts`(`guidCache` を `chrome.storage.local` キー `guids:<repoKey>` で実装、save はマージ)

- [ ] **Step 1: 実装 + typecheck/test/build/e2e 全通し**
- [ ] **Step 2: Commit** — `feat: wire guid cache into background worker`
- [ ] **Step 3: push + PR 作成。マージはユーザー確認待ち**(機能本体)

---

## PR 3 — `test/full-stack-e2e`(自己マージ可)

### Task 10: e2e ビルド変種 + full-stack スペック

**Files:**
- Modify: `extension/build.mjs`(`--e2e` で manifest の host_permissions に `http://127.0.0.1/*` を追加して dist へ書き出し)
- Modify: `extension/package.json`(`"e2e": "node build.mjs --e2e && playwright test"`)
- Create: `extension/e2e/full.spec.ts`(node:http サーバ + `launchPersistentContext` + `--load-extension`)

**シナリオ:** ローカルサーバに PR ページ fixture と canned GitHub API(`/api/v3/...`: pulls / compare / files / contents raw / search)を実装 → options ページ(`chrome-extension://<id>/options.html`)で PAT とサーバ URL を保存(A1 の動的登録が発火。host_permissions 済みなので prompt なし)→ PR ページで検出 → 実 background(実 fetch)→ 実 WASM diff → Shadow DOM 描画 → PR 外 guid が Code Search 経由で実名解決されることまで検証。

- [ ] Step 1: サーバ+スペック実装 → ローカルで `npm run e2e` PASS
- [ ] Step 2: Commit — `test: add full-stack e2e through real extension`

### Task 11: 25MB ガードの full-stack ケース

- [ ] contents 応答を 26MB(同一内容の有効 YAML)にし、`Render anyway` ボタン表示 → クリック → `No semantic changes` を検証
- [ ] Commit — `test: cover oversized render gate end to end`

### Task 12: PR 3 作成 → CI green → 自己マージ

- [ ] push、PR、CI green、squash 自己マージ

---

## Self-Review 済み

- spec A1〜A4 それぞれ Task 1-3 / 4-6 / 7-8 / 10-11 が対応。PR 分割は spec の表の通り
- 型シグネチャは Task 間で一貫(`GuidCache`・`searchMetaByGuid` の戻りは asset path・`too-large` 応答形)
- ポート付き match pattern 不可の制約は ghesOrigins のテストで固定
