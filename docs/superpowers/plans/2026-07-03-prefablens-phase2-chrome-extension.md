# PrefabLens Phase 2(Chrome 拡張ウォーキングスケルトン)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub PR の Files changed で Unity YAML(`.prefab`/`.unity`/`.asset`)の意味的 diff をインライン表示する Chrome 拡張(MV3)を、Phase 1 core の WASM 再利用で端から端まで通す。

**Architecture:** content script が検出・トグル・描画を担い、background Service Worker が PAT・GitHub API・WASM diff・guid 解決を担う。core(Zig)は `core/src/wasm.zig` の薄い C ABI ラッパで freestanding WASM 化し、ロジックは無改造。renderer は Shadow DOM の純関数。

**Tech Stack:** Zig 0.16.0(wasm32-freestanding, ReleaseSmall)/ TypeScript(strict)/ esbuild / vitest + jsdom / Playwright(スモーク1本)/ Node 22(`node --test` で WASM ゴールデン)。

## 設計からの確定事項・逸脱(承認済み設計の「未解決事項」の解決)

- **WASM は background Service Worker 上で実行する**(設計図の「content が Web Worker を生成」から変更)。理由: (1) content script(ページ origin)から `chrome-extension://` URL の Worker は cross-origin で生成できない、(2) blob URL Worker は GitHub ページの CSP(`worker-src`)に阻まれる、(3) `chrome.runtime` メッセージは JSON 直列化なのでバイト列の content 往復は base64 が必要で無駄。SW はページのメインスレッド外なので「GitHub ページのジャンクゼロ」(§5.7)は満たされる。設計の `worker/` ディレクトリは `src/wasm/`(WASM ローダ+差分モジュール)として background 内に置き、seam(`Differ` インターフェース)は保つので、後で offscreen document + Worker に移す場合も呼び出し側は無改造。
- **GitHub API**: `GET /repos/{o}/{r}/pulls/{n}`(base/head SHA)→ `GET /repos/{o}/{r}/compare/{base}...{head}`(**merge-base** を before 側 ref にする。GitHub の PR diff は base ブランチ先端ではなく merge-base 比較のため)→ `GET /repos/{o}/{r}/pulls/{n}/files`(per_page=100 でページング)→ `GET /repos/{o}/{r}/contents/{path}?ref=` + `Accept: application/vnd.github.raw+json`(blob 取得、404 = 片側なし)。
- **host_permissions は `https://api.github.com/*` のみ**。baseURL 設定は保存し API クライアントは対応する(github.com 以外 → `<origin>/api/v3`)が、GHES ドメインへの content script 動的登録・権限リクエストは follow-up。
- **light/dark**: `html[data-color-mode]` を描画時に読む。`auto` は `matchMedia('(prefers-color-scheme: dark)')`。
- **WASM エラーの ABI**: `diff()` は失敗時も長さ前置 JSON を返す。スキーマ `{"schema":"prefablens.error.v1","error":"<ErrorName>"}`(新規)。null 返却は OOM のみ。

## Global Constraints

- Zig 0.16.0 / zls 0.16.0(mise 管理)。Node は mise に `node = '22'` を追加。
- WASM gzip サイズ: **目標 ≤ 80 KB、150 KB 超で CI 失敗**(親仕様 §5.7)。ビルドは ReleaseSmall。
- diff JSON スキーマは Phase 1 の `prefablens.diff.v1` を厳守(core 出力は 1 バイトも変えない)。
- PAT は background に閉じる。content/renderer にトークンを渡さない。UI・コンソールに raw エラーやトークンを漏らさない(Phase 1 のエラー方針踏襲)。
- トグル既定は Raw(GitHub 既定表示のまま)。検出失敗時は無害に何もしない。
- レンダリングは `textContent` のみ使用(リポジトリ内容由来の文字列を `innerHTML` に入れない — XSS 防止)。
- TypeScript strict。テストは vitest(TS 単体)+ `node --test`(WASM ゴールデン)+ Playwright(スモーク1本)。
- コミットは repo 慣習の Conventional Commits(`feat(core):` `feat(extension):` `test(extension):` `ci:` 等)。

## ファイル構成(このプランで作るもの)

```
core/src/wasm.zig                    # C ABI ラッパ(alloc/free/diff)
core/tests/wasm_golden.test.mjs      # Node で WASM ゴールデン照合
build.zig                            # `zig build wasm` ターゲット追加(変更)
mise.toml                            # node = '22' 追加(変更)
extension/
  manifest.json                      # MV3
  package.json / tsconfig.json / vitest.config.ts / playwright.config.ts
  build.mjs                          # esbuild マルチエントリ + wasm/manifest/html コピー
  scripts/check-wasm-size.mjs        # gzip サイズゲート
  src/types.ts                       # DiffV1 型・メッセージ型
  src/github/client.ts (+ .test.ts)  # apiBase / GithubClient / TokenProvider seam
  src/github/guids.ts (+ .test.ts)   # .meta 索引構築 / applyResolved
  src/wasm/differ.ts (+ .test.ts)    # createDiffer(WASM ロード・呼出・メモリ管理)
  src/background/handler.ts (+ .test.ts)  # semanticDiff オーケストレーション(DI)
  src/background/index.ts            # 実配線(chrome.runtime.onMessage)
  src/renderer/render.ts (+ .test.ts)     # Shadow DOM ツリー描画・テーマ
  src/content/detect.ts (+ .test.ts)      # Unity ファイル検出・PR URL パース
  src/content/toggle.ts (+ .test.ts)      # [Raw | Semantic] トグル
  src/content/index.ts               # オーケストレーション(observer・状態)
  src/options/options.html / options.ts (+ .test.ts)
  e2e/fixtures/pr-files.html         # 最小 PR ページ複製フィクスチャ
  e2e/smoke.spec.ts                  # 検出→トグル→描画スモーク
.github/workflows/ci.yml             # extension ジョブ追加(変更)
```

---

### Task 1: WASM C ABI ラッパ + `zig build wasm` + Node ゴールデンテスト

**Files:**
- Create: `core/src/wasm.zig`
- Create: `core/tests/wasm_golden.test.mjs`
- Modify: `build.zig`(末尾に wasm ターゲット追加)
- Modify: `mise.toml`(node 追加)

**Interfaces:**
- Consumes: `core/src/root.zig` の `diffToJson(arena, before, after) ![]u8`(既存・無改造)
- Produces: WASM exports `alloc(len: usize) ?[*]u8` / `free(ptr: ?[*]u8, len: usize)` / `diff(before_ptr, before_len, after_ptr, after_len) ?[*]u8`(戻り値は **u32 リトルエンディアン長さ前置** の JSON バイト列。成功 = `prefablens.diff.v1`、失敗 = `prefablens.error.v1`、null = OOM)。成果物 `zig-out/bin/prefablens.wasm`。Task 5 の TS ラッパと Task 2 の build.mjs がこれに依存。

- [ ] **Step 1: mise に Node を追加**

`mise.toml` を次の内容にする:

```toml
[tools]
zig = '0.16.0'
zls = '0.16.0'
node = '22'
```

Run: `mise install && node --version`
Expected: `v22.x.x` が表示される

- [ ] **Step 2: 失敗するテストを書く(Node ゴールデン)**

`core/tests/wasm_golden.test.mjs` を作成。ゴールデン文字列は `core/src/json.zig` のテスト「json: modified loose component matches golden」と同一(WASM 経由でもネイティブと同一出力であることの検証)。

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const wasmUrl = new URL('../../zig-out/bin/prefablens.wasm', import.meta.url);
const { instance } = await WebAssembly.instantiate(await readFile(wasmUrl));
const exports = instance.exports;

function callDiff(before, after) {
  const enc = new TextEncoder();
  const b = enc.encode(before);
  const a = enc.encode(after);
  const bp = b.length ? exports.alloc(b.length) : 0;
  const ap = a.length ? exports.alloc(a.length) : 0;
  // ビューは最後の alloc の後に作る: memory.grow で古い ArrayBuffer は detach される
  new Uint8Array(exports.memory.buffer, bp, b.length).set(b);
  new Uint8Array(exports.memory.buffer, ap, a.length).set(a);
  const rp = exports.diff(bp, b.length, ap, a.length);
  assert.notEqual(rp, 0, 'diff returned null (OOM)');
  const len = new DataView(exports.memory.buffer).getUint32(rp, true);
  const json = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, rp + 4, len));
  exports.free(rp, 4 + len);
  if (b.length) exports.free(bp, b.length);
  if (a.length) exports.free(ap, a.length);
  return json;
}

const BEFORE = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5`;

const AFTER = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.8`;

const GOLDEN = '{"schema":"prefablens.diff.v1","unresolvedGuids":["def"],"roots":[],"loose":[{"kind":"component","fileId":"11400000","classId":114,"typeName":"MonoBehaviour","scriptGuid":"def","status":"modified","fields":[{"path":"volume","status":"modified","before":"0.5","after":"0.8"}]}]}';

test('wasm diff matches the native golden JSON', () => {
  assert.equal(callDiff(BEFORE, AFTER), GOLDEN);
});

test('empty before (added file) still yields a diff.v1 document', () => {
  const json = JSON.parse(callDiff('', AFTER));
  assert.equal(json.schema, 'prefablens.diff.v1');
});

test('hostile nesting returns a clean error.v1 payload, not a trap', () => {
  // parser の max_nesting_depth は 128(core/src/parser.zig)。200 段で確実に超える。
  let src = '--- !u!1 &1\nGameObject:\n';
  for (let depth = 1; depth <= 200; depth++) src += '  '.repeat(depth) + 'a:\n';
  const json = JSON.parse(callDiff(src, src));
  assert.equal(json.schema, 'prefablens.error.v1');
  assert.equal(json.error, 'NestingTooDeep');
});

test('repeated calls do not leak or corrupt state (pure, re-entrant)', () => {
  for (let i = 0; i < 50; i++) assert.equal(callDiff(BEFORE, AFTER), GOLDEN);
});
```

- [ ] **Step 3: テストを実行して失敗を確認**

Run: `node --test core/tests/`
Expected: FAIL(`ENOENT ... prefablens.wasm` — まだビルドしていない)

- [ ] **Step 4: `core/src/wasm.zig` を実装**

```zig
//! WASM C ABI ラッパ(親仕様 §5.6)。diff 1 回 = 1 arena、グローバル可変状態なし。
//! 戻り値は u32(LE)長さ前置の JSON バイト列。呼び出し側が free(ptr, 4 + len) で解放する。
const std = @import("std");
const core = @import("root.zig");

const gpa = std.heap.wasm_allocator;

export fn alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    if (len == 0) return;
    gpa.free(p[0..len]);
}

export fn diff(
    before_ptr: ?[*]const u8,
    before_len: usize,
    after_ptr: ?[*]const u8,
    after_len: usize,
) ?[*]u8 {
    const before: []const u8 = if (before_ptr) |p| p[0..before_len] else "";
    const after: []const u8 = if (after_ptr) |p| p[0..after_len] else "";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = core.diffToJson(arena, before, after) catch |err| {
        const msg = std.fmt.allocPrint(
            arena,
            "{{\"schema\":\"prefablens.error.v1\",\"error\":\"{s}\"}}",
            .{@errorName(err)},
        ) catch return null;
        return packResult(msg);
    };
    return packResult(json);
}

// arena の外(呼び出し側所有)へコピーして長さ前置する。
fn packResult(json: []const u8) ?[*]u8 {
    const out = gpa.alloc(u8, 4 + json.len) catch return null;
    std.mem.writeInt(u32, out[0..4], @intCast(json.len), .little);
    @memcpy(out[4..], json);
    return out.ptr;
}
```

- [ ] **Step 5: `build.zig` に wasm ターゲットを追加**

`build.zig` の `pub fn build` 末尾(perf_step の後)に追加:

```zig
    const wasm = b.addExecutable(.{
        .name = "prefablens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/src/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the core as a freestanding WASM library");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
```

注: `entry`/`rdynamic` のフィールド位置は Zig バージョンで動くことがある。コンパイルエラーになる場合は `zig build --help` とエラーメッセージに従い、`createModule` のオプション側へ移す(意図は「エントリポイント無し・全 `export fn` をエクスポート」)。

Run: `zig build wasm && ls -la zig-out/bin/prefablens.wasm`
Expected: `prefablens.wasm` が生成される

- [ ] **Step 6: テストを実行して成功を確認**

Run: `node --test core/tests/`
Expected: PASS(4 tests)

- [ ] **Step 7: 既存テスト・perf が壊れていないことを確認**

Run: `zig build test && zig build perf`
Expected: どちらも成功(core ロジックは無改造なので当然通る)

- [ ] **Step 8: サイズを目視確認**

Run: `gzip -9 -c zig-out/bin/prefablens.wasm | wc -c`
Expected: 81920(80 KB)以下が目標。超えていても 153600(150 KB)以下なら続行(ゲートは Task 11)。

- [ ] **Step 9: Commit**

```bash
git add core/src/wasm.zig core/tests/wasm_golden.test.mjs build.zig mise.toml
git commit -m "feat(core): add freestanding WASM target with C ABI wrapper"
```

---

### Task 2: 拡張スキャフォールド(esbuild + manifest + 型定義)

**Files:**
- Create: `extension/package.json`, `extension/tsconfig.json`, `extension/vitest.config.ts`, `extension/build.mjs`, `extension/manifest.json`, `extension/.gitignore`
- Create: `extension/src/types.ts`
- Create: `extension/src/content/index.ts`, `extension/src/background/index.ts`, `extension/src/options/options.ts`(いずれもプレースホルダ), `extension/src/options/options.html`

**Interfaces:**
- Consumes: `zig-out/bin/prefablens.wasm`(Task 1)
- Produces: `npm run build` → `extension/dist/`(content.js / background.js / options.js / options.html / manifest.json / prefablens.wasm)。`src/types.ts` の型(下記)を Task 3〜10 全部が import する。

- [ ] **Step 1: npm プロジェクトを初期化**

```bash
cd extension
npm init -y
npm install -D typescript esbuild vitest jsdom @types/chrome @playwright/test
```

その後 `package.json` を編集して次の形にする(devDependencies は npm が入れたバージョンのまま):

```json
{
  "name": "prefablens-extension",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "build": "node build.mjs",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "size": "node scripts/check-wasm-size.mjs",
    "e2e": "playwright test"
  }
}
```

- [ ] **Step 2: tsconfig / vitest 設定**

`extension/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "types": ["chrome"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src", "e2e", "playwright.config.ts", "vitest.config.ts"]
}
```

`extension/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { include: ['src/**/*.test.ts'] },
});
```

`extension/.gitignore`:

```
node_modules/
dist/
test-results/
```

- [ ] **Step 3: `src/types.ts`(diff.v1 の TS 型とメッセージプロトコル)**

```ts
// prefablens.diff.v1 (core/src/json.zig の出力と 1:1)
export type Status = 'added' | 'removed' | 'modified' | 'unchanged';

export type RefValue = { ref: { fileId: string; guid: string | null; type: number | null } };
export type FieldValue = string | RefValue | null;

export type FieldDiff = { path: string; status: Status; before: FieldValue; after: FieldValue };

export type ComponentDiff = {
  kind: 'component';
  fileId: string;
  classId: number;
  typeName: string;
  scriptGuid: string | null;
  status: Status;
  fields: FieldDiff[];
};

export type GameObjectDiff = {
  kind: 'gameObject';
  fileId: string;
  name: string;
  status: Status;
  components: ComponentDiff[];
  children: GameObjectDiff[];
};

export type DiffV1 = {
  schema: 'prefablens.diff.v1';
  unresolvedGuids: string[];
  resolved?: Record<string, string>; // ホスト側(applyResolved)が付与
  roots: GameObjectDiff[];
  loose: ComponentDiff[];
};

export type DiffErrorV1 = { schema: 'prefablens.error.v1'; error: string };

// content ↔ background メッセージ(chrome.runtime は JSON 直列化のみ)
export type SemanticDiffRequest = {
  type: 'semanticDiff';
  owner: string;
  repo: string;
  prNumber: number;
  path: string;
};

export type BackgroundError = 'pat-missing' | 'auth-failed' | 'fetch-failed' | 'diff-failed';

export type SemanticDiffResponse = { ok: true; json: DiffV1 } | { ok: false; error: BackgroundError };
```

- [ ] **Step 4: manifest.json**

`extension/manifest.json`:

```json
{
  "manifest_version": 3,
  "name": "PrefabLens",
  "version": "0.1.0",
  "description": "Semantic diffs for Unity YAML files in GitHub pull requests",
  "permissions": ["storage"],
  "host_permissions": ["https://api.github.com/*"],
  "background": { "service_worker": "background.js" },
  "content_scripts": [
    {
      "matches": ["https://github.com/*"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ],
  "options_page": "options.html",
  "content_security_policy": {
    "extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"
  }
}
```

- [ ] **Step 5: プレースホルダのエントリと options.html**

`extension/src/content/index.ts` / `extension/src/background/index.ts` / `extension/src/options/options.ts` の 3 ファイルすべて、いったん次の 1 行のみ:

```ts
export {}; // populated in a later task
```

`extension/src/options/options.html`:

```html
<!doctype html>
<meta charset="utf-8" />
<title>PrefabLens Options</title>
<body>
  <script src="options.js"></script>
</body>
```

- [ ] **Step 6: build.mjs(esbuild マルチエントリ + アセットコピー)**

`extension/build.mjs`:

```js
import { build } from 'esbuild';
import { cpSync, mkdirSync } from 'node:fs';

mkdirSync('dist', { recursive: true });

await build({
  entryPoints: {
    content: 'src/content/index.ts',
    background: 'src/background/index.ts',
    options: 'src/options/options.ts',
  },
  bundle: true,
  format: 'iife',
  target: 'chrome120',
  minify: true,
  outdir: 'dist',
});

cpSync('manifest.json', 'dist/manifest.json');
cpSync('src/options/options.html', 'dist/options.html');
cpSync('../zig-out/bin/prefablens.wasm', 'dist/prefablens.wasm');
```

- [ ] **Step 7: ビルドと型チェックを検証**

Run: `cd extension && npm run build && npm run typecheck && ls dist`
Expected: `background.js content.js manifest.json options.html options.js prefablens.wasm` の 6 ファイル。typecheck エラーなし。

- [ ] **Step 8: Commit**

```bash
git add extension/ && git commit -m "feat(extension): scaffold MV3 extension with esbuild and diff.v1 types"
```

---

### Task 3: GitHub API クライアント(`github/client.ts`)

**Files:**
- Create: `extension/src/github/client.ts`
- Test: `extension/src/github/client.test.ts`

**Interfaces:**
- Consumes: `fetch`(コンストラクタ注入可、テスト用)
- Produces(Task 4・6 が使う):
  - `apiBase(baseUrl: string | undefined): string`
  - `class AuthError extends Error` / `class ApiError extends Error { status: number }`
  - `type PrFile = { path: string; status: string; previousPath?: string }`
  - `type PrRefs = { baseSha: string; headSha: string }`
  - `class GithubClient { constructor(base: string, token: string, fetchFn?: typeof fetch); getPrRefs(owner, repo, prNumber): Promise<PrRefs>; listPrFiles(owner, repo, prNumber): Promise<PrFile[]>; getFileAtRef(owner, repo, path, ref): Promise<Uint8Array | null> }`
  - `type TokenProvider = { getToken(): Promise<string | undefined> }` / `patTokenProvider`(将来 OAuth の差し込み口)

- [ ] **Step 1: 失敗するテストを書く**

`extension/src/github/client.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { ApiError, AuthError, GithubClient, apiBase } from './client';

// パス→レスポンスの固定表を返す fetch フェイク。呼び出しも記録する。
// 照合は url.includes(key) なのでキーは一意な部分文字列にすること
// (例: 'page=1' は 'per_page=100' にもマッチしてしまう — '&page=1' を使う)。
function fakeFetch(routes: Record<string, () => Response>) {
  const calls: Array<{ url: string; headers: Record<string, string> }> = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, headers: Object.fromEntries(Object.entries(init?.headers ?? {})) });
    for (const [suffix, make] of Object.entries(routes)) {
      if (url.includes(suffix)) return make();
    }
    return new Response('not found', { status: 404 });
  }) as typeof fetch;
  return { fn, calls };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

describe('apiBase', () => {
  it('defaults to api.github.com', () => {
    expect(apiBase(undefined)).toBe('https://api.github.com');
    expect(apiBase('https://github.com')).toBe('https://api.github.com');
  });
  it('maps GHES origins to <origin>/api/v3', () => {
    expect(apiBase('https://ghe.example.com')).toBe('https://ghe.example.com/api/v3');
  });
});

describe('GithubClient', () => {
  it('getPrRefs returns the merge base as baseSha', async () => {
    const { fn, calls } = fakeFetch({
      '/compare/base-tip...head-sha': () => json({ merge_base_commit: { sha: 'merge-base' } }),
      '/pulls/7': () => json({ base: { sha: 'base-tip' }, head: { sha: 'head-sha' } }),
    });
    const client = new GithubClient('https://api.github.com', 'tok', fn);
    const refs = await client.getPrRefs('o', 'r', 7);
    expect(refs).toEqual({ baseSha: 'merge-base', headSha: 'head-sha' });
    expect(calls[0]!.headers['authorization']).toBe('Bearer tok');
  });

  it('listPrFiles paginates past 100 entries', async () => {
    const page1 = Array.from({ length: 100 }, (_, i) => ({ filename: `f${i}.cs`, status: 'modified' }));
    const page2 = [{ filename: 'Assets/Foo.prefab', status: 'renamed', previous_filename: 'Assets/Old.prefab' }];
    const { fn } = fakeFetch({
      '&page=1': () => json(page1),
      '&page=2': () => json(page2),
    });
    const client = new GithubClient('https://api.github.com', 'tok', fn);
    const files = await client.listPrFiles('o', 'r', 1);
    expect(files).toHaveLength(101);
    expect(files[100]).toEqual({ path: 'Assets/Foo.prefab', status: 'renamed', previousPath: 'Assets/Old.prefab' });
  });

  it('getFileAtRef requests raw content with URL-encoded path segments', async () => {
    const { fn, calls } = fakeFetch({ '/contents/': () => new Response(new Uint8Array([1, 2, 3])) });
    const client = new GithubClient('https://api.github.com', 'tok', fn);
    const bytes = await client.getFileAtRef('o', 'r', 'Assets/My Prefab#1.prefab', 'sha1');
    expect([...bytes!]).toEqual([1, 2, 3]);
    expect(calls[0]!.url).toContain('/contents/Assets/My%20Prefab%231.prefab?ref=sha1');
    expect(calls[0]!.headers['accept']).toBe('application/vnd.github.raw+json');
  });

  it('getFileAtRef returns null on 404 (file absent on that side)', async () => {
    const { fn } = fakeFetch({});
    const client = new GithubClient('https://api.github.com', 'tok', fn);
    expect(await client.getFileAtRef('o', 'r', 'gone.prefab', 'sha1')).toBeNull();
  });

  it('maps 401/403 to AuthError and other failures to ApiError', async () => {
    const auth = new GithubClient('https://api.github.com', 'bad', fakeFetch({ '/pulls/1': () => json({}, 401) }).fn);
    await expect(auth.getPrRefs('o', 'r', 1)).rejects.toBeInstanceOf(AuthError);
    const boom = new GithubClient('https://api.github.com', 'tok', fakeFetch({ '/pulls/1': () => json({}, 500) }).fn);
    await expect(boom.getPrRefs('o', 'r', 1)).rejects.toBeInstanceOf(ApiError);
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/github/client.test.ts`
Expected: FAIL(`Cannot find module './client'` 相当)

- [ ] **Step 3: `client.ts` を実装**

```ts
export class AuthError extends Error {}
export class ApiError extends Error {
  constructor(readonly status: number) {
    super(`GitHub API error (HTTP ${status})`); // raw ボディは持たない(漏洩防止)
  }
}

export type PrFile = { path: string; status: string; previousPath?: string };
export type PrRefs = { baseSha: string; headSha: string };

export type TokenProvider = { getToken(): Promise<string | undefined> };
export const patTokenProvider: TokenProvider = {
  async getToken() {
    const stored = await chrome.storage.local.get('pat');
    return stored['pat'] as string | undefined;
  },
};

export function apiBase(baseUrl: string | undefined): string {
  if (!baseUrl) return 'https://api.github.com';
  const origin = new URL(baseUrl).origin;
  return origin === 'https://github.com' ? 'https://api.github.com' : `${origin}/api/v3`;
}

export class GithubClient {
  constructor(
    private readonly base: string,
    private readonly token: string,
    private readonly fetchFn: typeof fetch = fetch,
  ) {}

  private async request(path: string, accept: string): Promise<Response> {
    const res = await this.fetchFn(`${this.base}${path}`, {
      headers: {
        accept,
        authorization: `Bearer ${this.token}`,
        'x-github-api-version': '2022-11-28',
      },
    });
    if (res.status === 401 || res.status === 403) throw new AuthError('GitHub authentication failed');
    return res;
  }

  private async json<T>(path: string): Promise<T> {
    const res = await this.request(path, 'application/vnd.github+json');
    if (!res.ok) throw new ApiError(res.status);
    return res.json() as Promise<T>;
  }

  // before 側は merge-base: GitHub の PR diff は base ブランチ先端ではなく merge-base 比較。
  async getPrRefs(owner: string, repo: string, prNumber: number): Promise<PrRefs> {
    const pr = await this.json<{ base: { sha: string }; head: { sha: string } }>(
      `/repos/${owner}/${repo}/pulls/${prNumber}`,
    );
    const cmp = await this.json<{ merge_base_commit: { sha: string } }>(
      `/repos/${owner}/${repo}/compare/${pr.base.sha}...${pr.head.sha}`,
    );
    return { baseSha: cmp.merge_base_commit.sha, headSha: pr.head.sha };
  }

  async listPrFiles(owner: string, repo: string, prNumber: number): Promise<PrFile[]> {
    const out: PrFile[] = [];
    for (let page = 1; ; page++) {
      const batch = await this.json<Array<{ filename: string; status: string; previous_filename?: string }>>(
        `/repos/${owner}/${repo}/pulls/${prNumber}/files?per_page=100&page=${page}`,
      );
      for (const f of batch) out.push({ path: f.filename, status: f.status, previousPath: f.previous_filename });
      if (batch.length < 100) return out;
    }
  }

  /** ref 時点の生バイト列。その側にファイルが無ければ null。 */
  async getFileAtRef(owner: string, repo: string, path: string, ref: string): Promise<Uint8Array | null> {
    const encoded = path.split('/').map(encodeURIComponent).join('/');
    const res = await this.request(
      `/repos/${owner}/${repo}/contents/${encoded}?ref=${ref}`,
      'application/vnd.github.raw+json',
    );
    if (res.status === 404) return null;
    if (!res.ok) throw new ApiError(res.status);
    return new Uint8Array(await res.arrayBuffer());
  }
}
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `cd extension && npx vitest run src/github/client.test.ts && npm run typecheck`
Expected: PASS(全ケース)、typecheck エラーなし

- [ ] **Step 5: Commit**

```bash
git add extension/src/github/ && git commit -m "feat(extension): GitHub API client with merge-base refs and raw blob fetch"
```

---

### Task 4: guid 索引(`github/guids.ts`)

**Files:**
- Create: `extension/src/github/guids.ts`
- Test: `extension/src/github/guids.test.ts`

**Interfaces:**
- Consumes: `PrFile`(Task 3)、`DiffV1`(Task 2)
- Produces(Task 6 が使う):
  - `parseGuidFromMeta(meta: string): string | undefined`
  - `type MetaFetcher = (path: string, side: 'base' | 'head') => Promise<string | null>`
  - `buildGuidIndex(files: PrFile[], fetchMeta: MetaFetcher): Promise<Map<string, string>>`
  - `applyResolved(diff: DiffV1, index: Map<string, string>): DiffV1`

- [ ] **Step 1: 失敗するテストを書く**

`extension/src/github/guids.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { applyResolved, buildGuidIndex, parseGuidFromMeta } from './guids';
import type { DiffV1 } from '../types';

const META = `fileFormatVersion: 2
guid: 1234567890abcdef1234567890abcdef
MonoImporter:
  serializedVersion: 2`;

describe('parseGuidFromMeta', () => {
  it('extracts the guid line', () => {
    expect(parseGuidFromMeta(META)).toBe('1234567890abcdef1234567890abcdef');
  });
  it('returns undefined when absent', () => {
    expect(parseGuidFromMeta('fileFormatVersion: 2\n')).toBeUndefined();
  });
});

describe('buildGuidIndex', () => {
  const files = [
    { path: 'Assets/Scripts/Player.cs', status: 'modified' },
    { path: 'Assets/Scripts/Player.cs.meta', status: 'modified' },
    { path: 'Assets/Old.cs.meta', status: 'removed' },
  ];

  it('indexes changed .meta files, reading removed metas from the base side', async () => {
    const fetched: Array<[string, string]> = [];
    const index = await buildGuidIndex(files, async (path, side) => {
      fetched.push([path, side]);
      if (path === 'Assets/Scripts/Player.cs.meta') return META;
      if (path === 'Assets/Old.cs.meta') return 'guid: oldguid\n';
      return null;
    });
    expect(index.get('1234567890abcdef1234567890abcdef')).toBe('Assets/Scripts/Player.cs');
    expect(index.get('oldguid')).toBe('Assets/Old.cs');
    expect(fetched).toContainEqual(['Assets/Scripts/Player.cs.meta', 'head']);
    expect(fetched).toContainEqual(['Assets/Old.cs.meta', 'base']);
    expect(fetched).toHaveLength(2); // .meta 以外は fetch しない
  });

  it('skips metas that fail to fetch or parse', async () => {
    const index = await buildGuidIndex(files, async () => {
      throw new Error('boom');
    });
    expect(index.size).toBe(0);
  });
});

describe('applyResolved', () => {
  const diff: DiffV1 = {
    schema: 'prefablens.diff.v1',
    unresolvedGuids: ['aaa', 'bbb'],
    roots: [],
    loose: [],
  };

  it('attaches only referenced-and-resolvable guids (scoped like core)', () => {
    const index = new Map([
      ['aaa', 'Assets/A.cs'],
      ['zzz', 'Assets/Z.cs'],
    ]);
    const out = applyResolved(diff, index);
    expect(out.resolved).toEqual({ aaa: 'Assets/A.cs' }); // bbb 未解決、zzz は参照外
    expect(out).not.toBe(diff); // 入力は破壊しない
    expect(diff.resolved).toBeUndefined();
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/github/guids.test.ts`
Expected: FAIL(モジュール未定義)

- [ ] **Step 3: `guids.ts` を実装**

```ts
import type { DiffV1 } from '../types';
import type { PrFile } from './client';

/** cli/src/resolve.zig の parseGuid と同じ規則: 行頭(trim 後)の "guid:" を拾う。 */
export function parseGuidFromMeta(meta: string): string | undefined {
  for (const line of meta.split('\n')) {
    const t = line.trim();
    if (t.startsWith('guid:')) return t.slice('guid:'.length).trim();
  }
  return undefined;
}

export type MetaFetcher = (path: string, side: 'base' | 'head') => Promise<string | null>;

/** PR 内で変更された .meta のみから guid → asset path 索引を作る(設計スコープ)。removed は base 側から読む。 */
export async function buildGuidIndex(files: PrFile[], fetchMeta: MetaFetcher): Promise<Map<string, string>> {
  const index = new Map<string, string>();
  const metas = files.filter((f) => f.path.endsWith('.meta'));
  await Promise.all(
    metas.map(async (f) => {
      const side = f.status === 'removed' ? 'base' : 'head';
      const text = await fetchMeta(f.path, side).catch(() => null);
      if (!text) return;
      const guid = parseGuidFromMeta(text);
      if (guid) index.set(guid, f.path.slice(0, -'.meta'.length));
    }),
  );
  return index;
}

/** ホスト側解決の seam(親仕様 §4.3)。core の "resolved" と同じスコープ規則で付与する。 */
export function applyResolved(diff: DiffV1, index: Map<string, string>): DiffV1 {
  const resolved: Record<string, string> = {};
  for (const g of diff.unresolvedGuids) {
    const path = index.get(g);
    if (path !== undefined) resolved[g] = path;
  }
  return { ...diff, resolved };
}
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `cd extension && npx vitest run src/github/guids.test.ts && npm run typecheck`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add extension/src/github/guids.ts extension/src/github/guids.test.ts
git commit -m "feat(extension): guid index from PR-changed .meta files with resolved seam"
```

---

### Task 5: WASM TS ラッパ(`wasm/differ.ts`)

**Files:**
- Create: `extension/src/wasm/differ.ts`
- Test: `extension/src/wasm/differ.test.ts`(実 WASM に対して実行)

**Interfaces:**
- Consumes: Task 1 の WASM exports(alloc/free/diff、u32 LE 長さ前置)
- Produces(Task 6 が使う):
  - `class DiffError extends Error`
  - `type Differ = { diff(before: Uint8Array, after: Uint8Array): DiffV1 }`
  - `createDiffer(wasmBytes: BufferSource): Promise<Differ>`(chrome API 非依存 — バイト列を注入する)

- [ ] **Step 1: 失敗するテストを書く**

`extension/src/wasm/differ.test.ts`:

```ts
import { readFileSync } from 'node:fs';
import { beforeAll, describe, expect, it } from 'vitest';
import { DiffError, createDiffer, type Differ } from './differ';

const enc = new TextEncoder();
const BEFORE = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5`);
const AFTER = enc.encode(`--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.8`);

let differ: Differ;
beforeAll(async () => {
  const bytes = readFileSync(new URL('../../../zig-out/bin/prefablens.wasm', import.meta.url));
  differ = await createDiffer(bytes);
});

describe('createDiffer', () => {
  it('returns a parsed diff.v1 document', () => {
    const json = differ.diff(BEFORE, AFTER);
    expect(json.schema).toBe('prefablens.diff.v1');
    expect(json.unresolvedGuids).toEqual(['def']);
    expect(json.loose[0]!.fields[0]).toEqual({ path: 'volume', status: 'modified', before: '0.5', after: '0.8' });
  });

  it('handles empty before (added file)', () => {
    expect(differ.diff(new Uint8Array(0), AFTER).schema).toBe('prefablens.diff.v1');
  });

  it('throws DiffError with the error name on core failure', () => {
    let src = '--- !u!1 &1\nGameObject:\n';
    for (let d = 1; d <= 200; d++) src += '  '.repeat(d) + 'a:\n';
    const hostile = enc.encode(src);
    expect(() => differ.diff(hostile, hostile)).toThrowError(/NestingTooDeep/);
    expect(() => differ.diff(hostile, hostile)).toThrowError(DiffError);
  });

  it('is re-entrant across many calls', () => {
    for (let i = 0; i < 50; i++) expect(differ.diff(BEFORE, AFTER).schema).toBe('prefablens.diff.v1');
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/wasm/differ.test.ts`
Expected: FAIL(モジュール未定義)。※ `zig build wasm` 済みであること(Task 1)。

- [ ] **Step 3: `differ.ts` を実装**

```ts
import type { DiffErrorV1, DiffV1 } from '../types';

export class DiffError extends Error {}

export type Differ = { diff(before: Uint8Array, after: Uint8Array): DiffV1 };

type Exports = {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  free(ptr: number, len: number): void;
  diff(bp: number, bl: number, ap: number, al: number): number;
};

export async function createDiffer(wasmBytes: BufferSource): Promise<Differ> {
  const { instance } = await WebAssembly.instantiate(wasmBytes);
  const exp = instance.exports as unknown as Exports;

  return {
    diff(before, after) {
      const bp = before.length ? exp.alloc(before.length) : 0;
      const ap = after.length ? exp.alloc(after.length) : 0;
      // コピーは最後の alloc の後: memory.grow で古いビューは detach される
      new Uint8Array(exp.memory.buffer, bp, before.length).set(before);
      new Uint8Array(exp.memory.buffer, ap, after.length).set(after);
      const rp = exp.diff(bp, before.length, ap, after.length);
      try {
        if (rp === 0) throw new DiffError('OutOfMemory');
        const len = new DataView(exp.memory.buffer).getUint32(rp, true);
        const text = new TextDecoder().decode(new Uint8Array(exp.memory.buffer, rp + 4, len));
        exp.free(rp, 4 + len);
        const parsed = JSON.parse(text) as DiffV1 | DiffErrorV1;
        if (parsed.schema !== 'prefablens.diff.v1') throw new DiffError((parsed as DiffErrorV1).error);
        return parsed;
      } finally {
        if (before.length) exp.free(bp, before.length);
        if (after.length) exp.free(ap, after.length);
      }
    },
  };
}
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `cd extension && npx vitest run src/wasm/differ.test.ts && npm run typecheck`
Expected: PASS(4 ケース)

- [ ] **Step 5: Commit**

```bash
git add extension/src/wasm/ && git commit -m "feat(extension): WASM differ wrapper with length-prefixed ABI"
```

---

### Task 6: background オーケストレーション(`background/handler.ts` + `background/index.ts`)

**Files:**
- Create: `extension/src/background/handler.ts`
- Create: `extension/src/background/index.ts`(プレースホルダを置換)
- Test: `extension/src/background/handler.test.ts`

**Interfaces:**
- Consumes: `GithubClient`/`apiBase`/`AuthError`(Task 3)、`buildGuidIndex`/`applyResolved`(Task 4)、`Differ`/`DiffError`/`createDiffer`(Task 5)、メッセージ型(Task 2)
- Produces: `createHandler(deps: Deps): (req: SemanticDiffRequest) => Promise<SemanticDiffResponse>`。`Deps = { getSettings(): Promise<{ pat?: string; baseUrl?: string }>; makeClient(base: string, token: string): ClientLike; getDiffer(): Promise<Differ> }`。`index.ts` は `chrome.runtime.onMessage` に配線(Task 8 の content が送信)。

- [ ] **Step 1: 失敗するテストを書く**

`extension/src/background/handler.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { createHandler, type Deps } from './handler';
import { AuthError, type PrFile } from '../github/client';
import { DiffError, type Differ } from '../wasm/differ';
import type { DiffV1, SemanticDiffRequest } from '../types';

const REQ: SemanticDiffRequest = { type: 'semanticDiff', owner: 'o', repo: 'r', prNumber: 1, path: 'Assets/Foo.prefab' };

const DIFF: DiffV1 = { schema: 'prefablens.diff.v1', unresolvedGuids: ['g1'], roots: [], loose: [] };

function makeDeps(overrides?: {
  files?: PrFile[];
  contents?: Record<string, string>; // `${path}@${ref}` → text
  diff?: Differ['diff'];
  pat?: string | undefined;
}) {
  const files = overrides?.files ?? [{ path: 'Assets/Foo.prefab', status: 'modified' }];
  const contents = overrides?.contents ?? { 'Assets/Foo.prefab@base-sha': 'b', 'Assets/Foo.prefab@head-sha': 'a' };
  const getFileAtRef = vi.fn(async (_o: string, _r: string, path: string, ref: string) => {
    const text = contents[`${path}@${ref}`];
    return text === undefined ? null : new TextEncoder().encode(text);
  });
  const client = {
    getPrRefs: vi.fn(async () => ({ baseSha: 'base-sha', headSha: 'head-sha' })),
    listPrFiles: vi.fn(async () => files),
    getFileAtRef,
  };
  const differ: Differ = { diff: overrides?.diff ?? vi.fn(() => DIFF) };
  const deps: Deps = {
    getSettings: async () => ({ pat: 'pat' in (overrides ?? {}) ? overrides!.pat : 'tok', baseUrl: undefined }),
    makeClient: () => client,
    getDiffer: async () => differ,
  };
  return { deps, client, differ };
}

describe('createHandler', () => {
  it('returns pat-missing without touching the network', async () => {
    const { deps, client } = makeDeps({ pat: undefined });
    const res = await createHandler(deps)(REQ);
    expect(res).toEqual({ ok: false, error: 'pat-missing' });
    expect(client.getPrRefs).not.toHaveBeenCalled();
  });

  it('diffs base/head blobs and attaches resolved guids', async () => {
    const { deps } = makeDeps({
      files: [
        { path: 'Assets/Foo.prefab', status: 'modified' },
        { path: 'Assets/S.cs.meta', status: 'modified' },
      ],
      contents: {
        'Assets/Foo.prefab@base-sha': 'b',
        'Assets/Foo.prefab@head-sha': 'a',
        'Assets/S.cs.meta@head-sha': 'guid: g1\n',
      },
    });
    const res = await createHandler(deps)(REQ);
    expect(res).toEqual({ ok: true, json: { ...DIFF, resolved: { g1: 'Assets/S.cs' } } });
  });

  it('uses an empty before for added files without fetching the base side', async () => {
    const diff = vi.fn(() => DIFF);
    const { deps, client } = makeDeps({ files: [{ path: 'Assets/Foo.prefab', status: 'added' }], diff });
    await createHandler(deps)(REQ);
    const baseFetches = client.getFileAtRef.mock.calls.filter(
      (c) => c[2] === 'Assets/Foo.prefab' && c[3] === 'base-sha',
    );
    expect(baseFetches).toHaveLength(0);
    expect(diff.mock.calls[0]![0]).toHaveLength(0); // before は空
  });

  it('reads renamed files from previousPath on the base side', async () => {
    const { deps, client } = makeDeps({
      files: [{ path: 'Assets/Foo.prefab', status: 'renamed', previousPath: 'Assets/Old.prefab' }],
      contents: { 'Assets/Old.prefab@base-sha': 'b', 'Assets/Foo.prefab@head-sha': 'a' },
    });
    const res = await createHandler(deps)(REQ);
    expect(res.ok).toBe(true);
    expect(client.getFileAtRef).toHaveBeenCalledWith('o', 'r', 'Assets/Old.prefab', 'base-sha');
  });

  it('caches PR context across calls (refs/files/guid index fetched once)', async () => {
    const { deps, client } = makeDeps();
    const handle = createHandler(deps);
    await handle(REQ);
    await handle({ ...REQ, path: 'Assets/Foo.prefab' });
    expect(client.getPrRefs).toHaveBeenCalledTimes(1);
    expect(client.listPrFiles).toHaveBeenCalledTimes(1);
  });

  it('maps AuthError / DiffError / other failures to stable error codes', async () => {
    const auth = makeDeps();
    auth.client.getPrRefs.mockRejectedValue(new AuthError('x'));
    expect(await createHandler(auth.deps)(REQ)).toEqual({ ok: false, error: 'auth-failed' });

    const bad = makeDeps({
      diff: () => {
        throw new DiffError('NestingTooDeep');
      },
    });
    expect(await createHandler(bad.deps)(REQ)).toEqual({ ok: false, error: 'diff-failed' });

    const net = makeDeps();
    net.client.listPrFiles.mockRejectedValue(new Error('socket'));
    expect(await createHandler(net.deps)(REQ)).toEqual({ ok: false, error: 'fetch-failed' });
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/background/handler.test.ts`
Expected: FAIL(モジュール未定義)

- [ ] **Step 3: `handler.ts` を実装**

```ts
import { AuthError, apiBase, type GithubClient, type PrFile, type PrRefs } from '../github/client';
import { applyResolved, buildGuidIndex } from '../github/guids';
import { DiffError, type Differ } from '../wasm/differ';
import type { SemanticDiffRequest, SemanticDiffResponse } from '../types';

type ClientLike = Pick<GithubClient, 'getPrRefs' | 'listPrFiles' | 'getFileAtRef'>;

export type Deps = {
  getSettings(): Promise<{ pat?: string; baseUrl?: string }>;
  makeClient(base: string, token: string): ClientLike;
  getDiffer(): Promise<Differ>;
};

type PrContext = { refs: PrRefs; files: PrFile[]; guidIndex: Map<string, string> };

const EMPTY = new Uint8Array(0);

export function createHandler(deps: Deps): (req: SemanticDiffRequest) => Promise<SemanticDiffResponse> {
  // PR 単位のコンテキストキャッシュ(follow-up の repo+sha キャッシュの差し込み口)。
  // SW はいつ殺されてもよく、その場合は再取得するだけ。
  const contexts = new Map<string, Promise<PrContext>>();

  function loadContext(client: ClientLike, owner: string, repo: string, prNumber: number): Promise<PrContext> {
    const key = `${owner}/${repo}#${prNumber}`;
    let ctx = contexts.get(key);
    if (!ctx) {
      ctx = (async () => {
        const refs = await client.getPrRefs(owner, repo, prNumber);
        const files = await client.listPrFiles(owner, repo, prNumber);
        const guidIndex = await buildGuidIndex(files, async (path, side) => {
          const bytes = await client.getFileAtRef(owner, repo, path, side === 'base' ? refs.baseSha : refs.headSha);
          return bytes ? new TextDecoder().decode(bytes) : null;
        });
        return { refs, files, guidIndex };
      })();
      contexts.set(key, ctx);
      ctx.catch(() => contexts.delete(key)); // 失敗はキャッシュしない
    }
    return ctx;
  }

  return async function handle(req) {
    try {
      const settings = await deps.getSettings();
      if (!settings.pat) return { ok: false, error: 'pat-missing' };
      const client = deps.makeClient(apiBase(settings.baseUrl), settings.pat);
      const { refs, files, guidIndex } = await loadContext(client, req.owner, req.repo, req.prNumber);

      const file = files.find((f) => f.path === req.path);
      const status = file?.status ?? 'modified';
      const beforePath = file?.previousPath ?? req.path;

      const before =
        status === 'added' ? EMPTY : ((await client.getFileAtRef(req.owner, req.repo, beforePath, refs.baseSha)) ?? EMPTY);
      const after =
        status === 'removed' ? EMPTY : ((await client.getFileAtRef(req.owner, req.repo, req.path, refs.headSha)) ?? EMPTY);

      const differ = await deps.getDiffer();
      const json = differ.diff(before, after);
      return { ok: true, json: applyResolved(json, guidIndex) };
    } catch (err) {
      if (err instanceof AuthError) return { ok: false, error: 'auth-failed' };
      if (err instanceof DiffError) return { ok: false, error: 'diff-failed' };
      return { ok: false, error: 'fetch-failed' }; // raw エラーは応答に載せない
    }
  };
}
```

- [ ] **Step 4: `background/index.ts` を実配線に置換**

```ts
import { createHandler } from './handler';
import { GithubClient } from '../github/client';
import { createDiffer, type Differ } from '../wasm/differ';
import type { SemanticDiffRequest } from '../types';

let differ: Promise<Differ> | undefined;

const handle = createHandler({
  async getSettings() {
    const stored = await chrome.storage.local.get(['pat', 'baseUrl']);
    return { pat: stored['pat'] as string | undefined, baseUrl: stored['baseUrl'] as string | undefined };
  },
  makeClient: (base, token) => new GithubClient(base, token),
  getDiffer() {
    // 遅延シングルトン。SW が再起動したらフェッチし直すだけ。
    differ ??= fetch(chrome.runtime.getURL('prefablens.wasm'))
      .then((r) => r.arrayBuffer())
      .then(createDiffer);
    return differ;
  },
});

chrome.runtime.onMessage.addListener((msg: SemanticDiffRequest, _sender, sendResponse) => {
  if (msg?.type !== 'semanticDiff') return;
  void handle(msg).then(sendResponse);
  return true; // 非同期応答
});
```

- [ ] **Step 5: テスト・型・ビルドを確認**

Run: `cd extension && npx vitest run src/background/handler.test.ts && npm run typecheck && npm run build`
Expected: すべて成功

- [ ] **Step 6: Commit**

```bash
git add extension/src/background/ && git commit -m "feat(extension): background semantic-diff orchestration with PR context cache"
```

---

### Task 7: Shadow DOM レンダラ(`renderer/render.ts`)

**Files:**
- Create: `extension/src/renderer/render.ts`
- Test: `extension/src/renderer/render.test.ts`(jsdom)

**Interfaces:**
- Consumes: `DiffV1` ほか型(Task 2)
- Produces(Task 8 が使う):
  - `render(root: ShadowRoot, diff: DiffV1): void`
  - `renderError(root: ShadowRoot, message: string): void`
  - `renderLoading(root: ShadowRoot): void`
  - `detectTheme(doc: Document): 'light' | 'dark'`

- [ ] **Step 1: 失敗するテストを書く**

`extension/src/renderer/render.test.ts`:

```ts
// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from 'vitest';
import { detectTheme, render, renderError } from './render';
import type { DiffV1 } from '../types';

const DIFF: DiffV1 = {
  schema: 'prefablens.diff.v1',
  unresolvedGuids: ['def', 'ghi'],
  resolved: { def: 'Assets/Scripts/Sound.cs' },
  roots: [
    {
      kind: 'gameObject',
      fileId: '1',
      name: 'Player',
      status: 'modified',
      components: [
        {
          kind: 'component',
          fileId: '2',
          classId: 114,
          typeName: 'MonoBehaviour',
          scriptGuid: 'def',
          status: 'modified',
          fields: [
            { path: 'volume', status: 'modified', before: '0.5', after: '0.8' },
            { path: 'm_Target', status: 'modified', before: { ref: { fileId: '100', guid: null, type: null } }, after: { ref: { fileId: '0', guid: 'ghi', type: 2 } } },
            { path: 'newField', status: 'added', before: null, after: '1' },
          ],
        },
      ],
      children: [
        { kind: 'gameObject', fileId: '3', name: 'Weapon', status: 'added', components: [], children: [] },
      ],
    },
  ],
  loose: [],
};

function freshRoot(): ShadowRoot {
  const host = document.createElement('div');
  document.body.append(host);
  return host.attachShadow({ mode: 'open' });
}

describe('render', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
    document.documentElement.removeAttribute('data-color-mode');
  });

  it('renders the GameObject hierarchy with statuses', () => {
    const root = freshRoot();
    render(root, DIFF);
    const gos = root.querySelectorAll('details.pl-go');
    expect(gos).toHaveLength(2);
    expect(gos[0]!.querySelector('summary')!.textContent).toContain('Player');
    expect(gos[1]!.classList.contains('pl-added')).toBe(true);
  });

  it('shows field values as before → after and resolves script guids', () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector('.pl-root')!.textContent!;
    expect(text).toContain('volume');
    expect(text).toContain('0.5');
    expect(text).toContain('0.8');
    expect(text).toContain('Assets/Scripts/Sound.cs'); // resolved guid
  });

  it('falls back to the raw guid when unresolved and to #fileId for local refs', () => {
    const root = freshRoot();
    render(root, DIFF);
    const text = root.querySelector('.pl-root')!.textContent!;
    expect(text).toContain('#100'); // local ref
    expect(text).toContain('ghi'); // unresolved guid stays visible
  });

  it('renders repo-controlled strings as text, never as markup', () => {
    const hostile: DiffV1 = {
      ...DIFF,
      roots: [{ kind: 'gameObject', fileId: '1', name: '<img src=x onerror=alert(1)>', status: 'added', components: [], children: [] }],
    };
    const root = freshRoot();
    render(root, hostile);
    expect(root.querySelector('img')).toBeNull();
    expect(root.textContent).toContain('<img src=x onerror=alert(1)>');
  });

  it('replaces previous content on re-render and shows an empty note for empty diffs', () => {
    const root = freshRoot();
    render(root, DIFF);
    render(root, { schema: 'prefablens.diff.v1', unresolvedGuids: [], roots: [], loose: [] });
    expect(root.querySelectorAll('details')).toHaveLength(0);
    expect(root.textContent).toContain('No semantic changes');
  });

  it('renderError shows a clean one-line message', () => {
    const root = freshRoot();
    renderError(root, 'Set a GitHub token in the PrefabLens options page.');
    expect(root.textContent).toContain('Set a GitHub token');
  });
});

describe('detectTheme', () => {
  it('follows html[data-color-mode]', () => {
    document.documentElement.setAttribute('data-color-mode', 'dark');
    expect(detectTheme(document)).toBe('dark');
    document.documentElement.setAttribute('data-color-mode', 'light');
    expect(detectTheme(document)).toBe('light');
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/renderer/render.test.ts`
Expected: FAIL(モジュール未定義)

- [ ] **Step 3: `render.ts` を実装**

```ts
import type { ComponentDiff, DiffV1, FieldValue, GameObjectDiff, Status } from '../types';

const STYLES = `
  :host { all: initial; }
  .pl-root {
    --pl-fg: #1f2328; --pl-muted: #59636e; --pl-border: #d1d9e0;
    --pl-added: #1a7f37; --pl-removed: #cf222e; --pl-modified: #9a6700;
    font: 12px/1.5 ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    color: var(--pl-fg); padding: 8px 12px; display: block;
  }
  .pl-root.pl-dark {
    --pl-fg: #f0f6fc; --pl-muted: #9198a1; --pl-border: #3d444d;
    --pl-added: #3fb950; --pl-removed: #f85149; --pl-modified: #d29922;
  }
  details { margin: 2px 0; border-left: 1px solid var(--pl-border); padding-left: 10px; }
  summary { cursor: pointer; user-select: none; }
  .pl-badge { font-weight: 600; margin-right: 6px; }
  .pl-added > summary .pl-badge { color: var(--pl-added); }
  .pl-removed > summary .pl-badge { color: var(--pl-removed); }
  .pl-modified > summary .pl-badge { color: var(--pl-modified); }
  .pl-script { color: var(--pl-muted); margin-left: 6px; }
  .pl-field { padding-left: 14px; }
  .pl-field .pl-path { color: var(--pl-muted); margin-right: 6px; }
  .pl-before { color: var(--pl-removed); }
  .pl-after { color: var(--pl-added); }
  .pl-arrow { color: var(--pl-muted); margin: 0 4px; }
  .pl-empty, .pl-error, .pl-loading { color: var(--pl-muted); margin: 0; }
  .pl-error { color: var(--pl-removed); }
`;

const BADGE: Record<Status, string> = { added: '+', removed: '−', modified: '~', unchanged: ' ' };

export function detectTheme(doc: Document): 'light' | 'dark' {
  const mode = doc.documentElement.getAttribute('data-color-mode');
  if (mode === 'dark') return 'dark';
  if (mode === 'light') return 'light';
  return doc.defaultView?.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export function render(root: ShadowRoot, diff: DiffV1): void {
  const container = mount(root);
  for (const go of diff.roots) container.append(renderGameObject(go, diff));
  for (const c of diff.loose) container.append(renderComponent(c, diff));
  if (!diff.roots.length && !diff.loose.length) {
    container.append(note('pl-empty', 'No semantic changes'));
  }
}

export function renderError(root: ShadowRoot, message: string): void {
  mount(root).append(note('pl-error', message));
}

export function renderLoading(root: ShadowRoot): void {
  mount(root).append(note('pl-loading', 'Computing semantic diff…'));
}

function mount(root: ShadowRoot): HTMLElement {
  root.replaceChildren();
  const doc = root.host.ownerDocument;
  const style = doc.createElement('style');
  style.textContent = STYLES;
  const container = doc.createElement('div');
  container.className = `pl-root pl-${detectTheme(doc)}`;
  root.append(style, container);
  return container;
}

function note(className: string, text: string): HTMLElement {
  const p = document.createElement('p');
  p.className = className;
  p.textContent = text;
  return p;
}

function renderGameObject(go: GameObjectDiff, diff: DiffV1): HTMLElement {
  const details = openDetails('pl-go', go.status);
  details.append(summaryLine(go.status, go.name));
  for (const c of go.components) details.append(renderComponent(c, diff));
  for (const child of go.children) details.append(renderGameObject(child, diff));
  return details;
}

function renderComponent(c: ComponentDiff, diff: DiffV1): HTMLElement {
  const details = openDetails('pl-comp', c.status);
  const summary = summaryLine(c.status, c.typeName);
  if (c.scriptGuid) {
    const script = document.createElement('span');
    script.className = 'pl-script';
    script.textContent = diff.resolved?.[c.scriptGuid] ?? `guid:${c.scriptGuid}`;
    summary.append(script);
  }
  details.append(summary);
  for (const f of c.fields) {
    const row = document.createElement('div');
    row.className = `pl-field pl-${f.status}`;
    const path = document.createElement('span');
    path.className = 'pl-path';
    path.textContent = f.path;
    row.append(path);
    if (f.before !== null) row.append(valueSpan('pl-before', f.before, diff));
    if (f.before !== null && f.after !== null) {
      const arrow = document.createElement('span');
      arrow.className = 'pl-arrow';
      arrow.textContent = '→';
      row.append(arrow);
    }
    if (f.after !== null) row.append(valueSpan('pl-after', f.after, diff));
    details.append(row);
  }
  return details;
}

function openDetails(kind: string, status: Status): HTMLDetailsElement {
  const details = document.createElement('details');
  details.open = true;
  details.className = `${kind} pl-${status}`;
  return details;
}

function summaryLine(status: Status, text: string): HTMLElement {
  const summary = document.createElement('summary');
  const badge = document.createElement('span');
  badge.className = 'pl-badge';
  badge.textContent = BADGE[status];
  const label = document.createElement('span');
  label.textContent = text;
  summary.append(badge, label);
  return summary;
}

function valueSpan(className: string, value: FieldValue, diff: DiffV1): HTMLElement {
  const span = document.createElement('span');
  span.className = className;
  span.textContent = formatValue(value, diff);
  return span;
}

function formatValue(value: FieldValue, diff: DiffV1): string {
  if (value === null) return '—';
  if (typeof value === 'string') return value;
  const { fileId, guid } = value.ref;
  if (guid === null) return `#${fileId}`; // ローカル参照
  return diff.resolved?.[guid] ?? `guid:${guid}`; // 外部参照(未解決は生 guid のまま)
}
```

- [ ] **Step 4: テストを実行して成功を確認**

Run: `cd extension && npx vitest run src/renderer/render.test.ts && npm run typecheck`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add extension/src/renderer/ && git commit -m "feat(extension): Shadow DOM tree renderer with light/dark themes"
```

---

### Task 8: content script(検出・トグル・オーケストレーション)

**Files:**
- Create: `extension/src/content/detect.ts`, `extension/src/content/toggle.ts`
- Modify: `extension/src/content/index.ts`(プレースホルダを置換)
- Test: `extension/src/content/detect.test.ts`, `extension/src/content/toggle.test.ts`

**Interfaces:**
- Consumes: `render`/`renderError`/`renderLoading`(Task 7)、メッセージ型(Task 2)、`chrome.runtime.sendMessage`(Task 6 の background)
- Produces:
  - `parsePrUrl(pathname: string): { owner: string; repo: string; prNumber: number } | null`
  - `scanUnityFiles(root: ParentNode): FileEntry[]`、`type FileEntry = { path: string; header: HTMLElement; content: HTMLElement }`
  - `createToggle(onSelect: (view: 'raw' | 'semantic') => void): HTMLElement`
  - `index.ts` は import 時に自動起動(E2E で検証)

- [ ] **Step 1: 失敗するテストを書く(detect)**

`extension/src/content/detect.test.ts`:

```ts
// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { parsePrUrl, scanUnityFiles } from './detect';

const FIXTURE = `
  <div class="file">
    <div class="file-header" data-path="Assets/Foo.prefab"><div class="file-actions"></div></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="Assets/Scenes/Main.unity"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file">
    <div class="file-header" data-path="src/main.cs"></div>
    <div class="js-file-content">raw diff</div>
  </div>
  <div class="file-header" data-path="Assets/Orphan.prefab"></div>
`;

describe('parsePrUrl', () => {
  it('matches the PR files tab', () => {
    expect(parsePrUrl('/owner/repo/pull/42/files')).toEqual({ owner: 'owner', repo: 'repo', prNumber: 42 });
    expect(parsePrUrl('/owner/repo/pull/42/files/abc123')).toEqual({ owner: 'owner', repo: 'repo', prNumber: 42 });
  });
  it('rejects other pages', () => {
    expect(parsePrUrl('/owner/repo/pull/42')).toBeNull();
    expect(parsePrUrl('/owner/repo/blob/main/a.prefab')).toBeNull();
  });
});

describe('scanUnityFiles', () => {
  it('finds .prefab/.unity/.asset containers and skips other files', () => {
    document.body.innerHTML = FIXTURE;
    const entries = scanUnityFiles(document);
    expect(entries.map((e) => e.path)).toEqual(['Assets/Foo.prefab', 'Assets/Scenes/Main.unity']);
    expect(entries[0]!.content.classList.contains('js-file-content')).toBe(true);
  });

  it('is harmless when the expected structure is missing (defensive selectors)', () => {
    document.body.innerHTML = '<div>totally different markup</div>';
    expect(scanUnityFiles(document)).toEqual([]);
  });
});
```

- [ ] **Step 2: 失敗するテストを書く(toggle)**

`extension/src/content/toggle.test.ts`:

```ts
// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';
import { createToggle } from './toggle';

describe('createToggle', () => {
  it('starts on Raw and reports selection changes', () => {
    const onSelect = vi.fn();
    const toggle = createToggle(onSelect);
    document.body.append(toggle);
    const [raw, semantic] = [...toggle.querySelectorAll('button')];
    expect(raw!.getAttribute('aria-pressed')).toBe('true');
    semantic!.click();
    expect(onSelect).toHaveBeenCalledWith('semantic');
    expect(semantic!.getAttribute('aria-pressed')).toBe('true');
    expect(raw!.getAttribute('aria-pressed')).toBe('false');
    raw!.click();
    expect(onSelect).toHaveBeenLastCalledWith('raw');
  });
});
```

- [ ] **Step 3: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/content/`
Expected: FAIL(モジュール未定義)

- [ ] **Step 4: `detect.ts` を実装**

```ts
const UNITY_PATH = /\.(prefab|unity|asset)$/i;

export type FileEntry = { path: string; header: HTMLElement; content: HTMLElement };

export function parsePrUrl(pathname: string): { owner: string; repo: string; prNumber: number } | null {
  const m = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/files(\/|$)/.exec(pathname);
  return m ? { owner: m[1]!, repo: m[2]!, prNumber: Number(m[3]!) } : null;
}

// GitHub の Files changed(クラシック DOM)を防御的に探す。合わなければ空配列で無害に終わる。
export function scanUnityFiles(root: ParentNode): FileEntry[] {
  const out: FileEntry[] = [];
  for (const header of root.querySelectorAll<HTMLElement>('.file-header[data-path]')) {
    const path = header.dataset['path'];
    if (!path || !UNITY_PATH.test(path)) continue;
    const container = header.closest('.file');
    const content = container?.querySelector<HTMLElement>('.js-file-content') ?? null;
    if (!content) continue;
    out.push({ path, header, content });
  }
  return out;
}
```

- [ ] **Step 5: `toggle.ts` を実装**

```ts
export type View = 'raw' | 'semantic';

export function createToggle(onSelect: (view: View) => void): HTMLElement {
  const wrap = document.createElement('span');
  wrap.setAttribute('data-prefablens-toggle', '');
  wrap.style.cssText = 'display:inline-flex;gap:0;margin-left:8px;vertical-align:middle;';

  const buttons: HTMLButtonElement[] = [];
  const select = (view: View) => {
    for (const b of buttons) {
      const active = b.dataset['view'] === view;
      b.setAttribute('aria-pressed', String(active));
      b.style.fontWeight = active ? '600' : '400';
    }
  };
  const make = (view: View, label: string) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = label;
    btn.dataset['view'] = view;
    btn.style.cssText =
      'font:11px system-ui;padding:1px 8px;border:1px solid #808080;background:transparent;color:inherit;cursor:pointer;';
    btn.addEventListener('click', () => {
      select(view);
      onSelect(view);
    });
    buttons.push(btn);
    return btn;
  };

  wrap.append(make('raw', 'Raw'), make('semantic', 'Semantic'));
  select('raw'); // 既定は Raw(GitHub 既定表示のまま)
  return wrap;
}
```

- [ ] **Step 6: `content/index.ts` を実装**

```ts
import { parsePrUrl, scanUnityFiles, type FileEntry } from './detect';
import { createToggle } from './toggle';
import { render, renderError, renderLoading } from '../renderer/render';
import type { BackgroundError, SemanticDiffRequest, SemanticDiffResponse } from '../types';

const ERROR_TEXT: Record<BackgroundError, string> = {
  'pat-missing': 'Set a GitHub token in the PrefabLens options page.',
  'auth-failed': 'GitHub authentication failed. Check your token in the PrefabLens options page.',
  'fetch-failed': 'Could not fetch file contents from GitHub.',
  'diff-failed': 'Could not compute a semantic diff for this file.',
};

function attach(): void {
  const pr = parsePrUrl(location.pathname);
  if (!pr) return;
  for (const entry of scanUnityFiles(document)) attachToggle(pr, entry);
}

function attachToggle(pr: { owner: string; repo: string; prNumber: number }, entry: FileEntry): void {
  if (entry.header.hasAttribute('data-prefablens')) return;
  entry.header.setAttribute('data-prefablens', '');

  let host: HTMLElement | undefined;
  let requested = false;

  const toggle = createToggle((view) => {
    if (view === 'raw') {
      entry.content.style.display = '';
      if (host) host.style.display = 'none';
      return;
    }
    entry.content.style.display = 'none';
    if (!host) {
      host = document.createElement('div');
      host.setAttribute('data-prefablens-view', '');
      host.attachShadow({ mode: 'open' });
      entry.content.after(host);
    }
    host.style.display = '';
    if (requested) return; // 結果はファイル単位でキャッシュ(再トグルで再フェッチしない)
    requested = true;
    const root = host.shadowRoot!;
    renderLoading(root);
    void requestDiff({ type: 'semanticDiff', ...pr, path: entry.path }).then((res) => {
      if (res.ok) render(root, res.json);
      else renderError(root, ERROR_TEXT[res.error]);
    });
  });
  entry.header.append(toggle);
}

function requestDiff(req: SemanticDiffRequest): Promise<SemanticDiffResponse> {
  return (chrome.runtime.sendMessage(req) as Promise<SemanticDiffResponse>).catch(() => ({
    ok: false as const,
    error: 'fetch-failed' as const,
  }));
}

// GitHub は SPA: 初回スキャン + MutationObserver で遅延ロード・タブ遷移に追従(200ms デバウンス)。
attach();
let scheduled = false;
new MutationObserver(() => {
  if (scheduled) return;
  scheduled = true;
  setTimeout(() => {
    scheduled = false;
    attach();
  }, 200);
}).observe(document.body, { childList: true, subtree: true });
```

- [ ] **Step 7: テスト・型・ビルドを確認**

Run: `cd extension && npx vitest run src/content/ && npm run typecheck && npm run build`
Expected: すべて成功

- [ ] **Step 8: Commit**

```bash
git add extension/src/content/ && git commit -m "feat(extension): detect Unity files in PR view and toggle semantic diff inline"
```

---

### Task 9: Options ページ(PAT・baseURL)

**Files:**
- Modify: `extension/src/options/options.html`, `extension/src/options/options.ts`
- Test: `extension/src/options/options.test.ts`

**Interfaces:**
- Consumes: `chrome.storage.local`(キーは `pat` / `baseUrl` — Task 6 の `getSettings` と一致)
- Produces: `initOptions(doc: Document, storage: { get(keys: string[]): Promise<Record<string, unknown>>; set(items: Record<string, unknown>): Promise<void> }): Promise<void>`

- [ ] **Step 1: 失敗するテストを書く**

`extension/src/options/options.test.ts`:

```ts
// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { OPTIONS_BODY, initOptions } from './options';

function fakeStorage(initial: Record<string, unknown> = {}) {
  const data = { ...initial };
  return {
    data,
    async get(keys: string[]) {
      return Object.fromEntries(keys.filter((k) => k in data).map((k) => [k, data[k]]));
    },
    async set(items: Record<string, unknown>) {
      Object.assign(data, items);
    },
  };
}

describe('initOptions', () => {
  it('loads stored values into the form', async () => {
    document.body.innerHTML = OPTIONS_BODY;
    await initOptions(document, fakeStorage({ pat: 'tok', baseUrl: 'https://ghe.example.com' }));
    expect(document.querySelector<HTMLInputElement>('#pat')!.value).toBe('tok');
    expect(document.querySelector<HTMLInputElement>('#baseUrl')!.value).toBe('https://ghe.example.com');
  });

  it('saves trimmed values and confirms', async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(document, storage);
    document.querySelector<HTMLInputElement>('#pat')!.value = '  tok  ';
    document.querySelector<HTMLButtonElement>('#save')!.click();
    await new Promise((r) => setTimeout(r, 0));
    expect(storage.data['pat']).toBe('tok');
    expect(document.querySelector('#status')!.textContent).toBe('Saved');
  });
});
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd extension && npx vitest run src/options/`
Expected: FAIL

- [ ] **Step 3: 実装**

`extension/src/options/options.ts`:

```ts
// フォーム本体を TS 側に持つ: options.html と jsdom テストで同一マークアップを共有する。
export const OPTIONS_BODY = `
  <h1>PrefabLens</h1>
  <p>
    <label>GitHub personal access token<br />
      <input id="pat" type="password" autocomplete="off" size="40" />
    </label>
  </p>
  <p>
    <label>GitHub base URL (leave empty for github.com)<br />
      <input id="baseUrl" type="url" placeholder="https://github.com" size="40" />
    </label>
  </p>
  <button id="save" type="button">Save</button>
  <span id="status" role="status"></span>
`;

type StorageLike = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export async function initOptions(doc: Document, storage: StorageLike): Promise<void> {
  const pat = doc.querySelector<HTMLInputElement>('#pat')!;
  const baseUrl = doc.querySelector<HTMLInputElement>('#baseUrl')!;
  const status = doc.querySelector<HTMLElement>('#status')!;

  const stored = await storage.get(['pat', 'baseUrl']);
  pat.value = (stored['pat'] as string | undefined) ?? '';
  baseUrl.value = (stored['baseUrl'] as string | undefined) ?? '';

  doc.querySelector<HTMLButtonElement>('#save')!.addEventListener('click', () => {
    void storage.set({ pat: pat.value.trim(), baseUrl: baseUrl.value.trim() }).then(() => {
      status.textContent = 'Saved';
    });
  });
}

if (typeof chrome !== 'undefined' && chrome.storage) {
  document.body.innerHTML = OPTIONS_BODY;
  void initOptions(document, chrome.storage.local);
}
```

`extension/src/options/options.html`(body は TS が生成するので空のまま):

```html
<!doctype html>
<meta charset="utf-8" />
<title>PrefabLens Options</title>
<body>
  <script src="options.js"></script>
</body>
```

- [ ] **Step 4: テスト・型・ビルドを確認**

Run: `cd extension && npx vitest run src/options/ && npm run typecheck && npm run build`
Expected: すべて成功

- [ ] **Step 5: Commit**

```bash
git add extension/src/options/ && git commit -m "feat(extension): options page for PAT and base URL"
```

---

### Task 10: Playwright スモーク E2E(検出 → トグル → 描画)

**Files:**
- Create: `extension/playwright.config.ts`, `extension/e2e/fixtures/pr-files.html`, `extension/e2e/smoke.spec.ts`

**Interfaces:**
- Consumes: `extension/dist/content.js`(ビルド済みバンドル — 実行前に `npm run build` 必須)、Task 8 の DOM 契約(`.file-header[data-path]` / `.js-file-content` / `[data-prefablens-view]`)
- Produces: `npm run e2e` で通るスモーク 1 本

- [ ] **Step 1: フィクスチャとコンフィグを作る**

`extension/e2e/fixtures/pr-files.html`(GitHub クラシック DOM の最小複製。実ページからの採取・本格 E2E は follow-up):

```html
<!doctype html>
<html data-color-mode="light">
  <head><meta charset="utf-8" /><title>PR fixture</title></head>
  <body>
    <div class="file">
      <div class="file-header" data-path="Assets/Foo.prefab">
        <span class="file-info">Assets/Foo.prefab</span>
      </div>
      <div class="js-file-content">raw github diff table</div>
    </div>
    <div class="file">
      <div class="file-header" data-path="README.md">
        <span class="file-info">README.md</span>
      </div>
      <div class="js-file-content">raw github diff table</div>
    </div>
  </body>
</html>
```

`extension/playwright.config.ts`:

```ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: 'e2e',
  use: { browserName: 'chromium' },
});
```

- [ ] **Step 2: 失敗するスモークを書く**

`extension/e2e/smoke.spec.ts`:

```ts
import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';

const fixture = readFileSync(new URL('./fixtures/pr-files.html', import.meta.url), 'utf8');

const cannedResponse = {
  ok: true,
  json: {
    schema: 'prefablens.diff.v1',
    unresolvedGuids: ['def'],
    resolved: {},
    roots: [],
    loose: [
      {
        kind: 'component',
        fileId: '11400000',
        classId: 114,
        typeName: 'MonoBehaviour',
        scriptGuid: 'def',
        status: 'modified',
        fields: [{ path: 'volume', status: 'modified', before: '0.5', after: '0.8' }],
      },
    ],
  },
};

test('detects a Unity file, toggles to Semantic, renders the tree', async ({ page }) => {
  // content script は URL(/pull/N/files)を見る: フィクスチャを PR の URL で返す
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  // background を固定応答でスタブ(この面の本物は handler.test.ts が担保)
  await page.addInitScript((res) => {
    (window as unknown as Record<string, unknown>)['chrome'] = {
      runtime: { sendMessage: () => Promise.resolve(res) },
    };
  }, cannedResponse);

  await page.goto('https://prefablens.test/owner/repo/pull/1/files');
  await page.addScriptTag({ path: 'dist/content.js' });

  // 検出: Unity ファイルにだけトグルが付く
  const unityHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await expect(unityHeader.getByRole('button', { name: 'Semantic' })).toBeVisible();
  const mdHeader = page.locator('.file-header[data-path="README.md"]');
  await expect(mdHeader.locator('[data-prefablens-toggle]')).toHaveCount(0);

  // トグル → 描画(Playwright は open shadow root を自動貫通する)
  await unityHeader.getByRole('button', { name: 'Semantic' }).click();
  const view = page.locator('[data-prefablens-view]');
  await expect(view).toContainText('MonoBehaviour');
  await expect(view).toContainText('volume');
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();

  // Raw に戻せる
  await unityHeader.getByRole('button', { name: 'Raw' }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeVisible();
  await expect(view).toBeHidden();
});
```

- [ ] **Step 3: ブラウザを入れて実行**

Run: `cd extension && npx playwright install chromium && npm run build && npm run e2e`
Expected: PASS(1 test)。初回は実装バグが出やすい箇所: `addScriptTag` 時点で `document.body` が既にあること(fixture は静的 HTML なので問題ないはず)、shadow root 内テキストのアサーション。

- [ ] **Step 4: Commit**

```bash
git add extension/e2e/ extension/playwright.config.ts
git commit -m "test(extension): Playwright smoke for detect-toggle-render pipeline"
```

---

### Task 11: WASM サイズゲート + CI 統合

**Files:**
- Create: `extension/scripts/check-wasm-size.mjs`
- Modify: `.github/workflows/ci.yml`(`extension` ジョブ追加)

**Interfaces:**
- Consumes: `zig-out/bin/prefablens.wasm`(Task 1)、`extension/` の npm スクリプト(Task 2〜10)
- Produces: `npm run size`(gzip ≤ 150 KB 強制・80 KB 目標表示)、CI ジョブ `extension`

- [ ] **Step 1: サイズゲートスクリプトを書く**

`extension/scripts/check-wasm-size.mjs`:

```js
import { readFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';

const TARGET_KB = 80; // 親仕様 §5.7 の目標
const LIMIT_KB = 150; // 超過で CI 失敗

const wasmUrl = new URL('../../zig-out/bin/prefablens.wasm', import.meta.url);
const gz = gzipSync(readFileSync(wasmUrl), { level: 9 }).length;
const kb = (gz / 1024).toFixed(1);

if (gz > LIMIT_KB * 1024) {
  console.error(`WASM gzip size ${kb} KB exceeds the ${LIMIT_KB} KB hard limit`);
  process.exit(1);
}
const verdict = gz > TARGET_KB * 1024 ? `over the ${TARGET_KB} KB target` : `within the ${TARGET_KB} KB target`;
console.log(`WASM gzip size: ${kb} KB (${verdict}, hard limit ${LIMIT_KB} KB)`);
```

Run: `cd extension && npm run size`
Expected: `WASM gzip size: NN.N KB (...)` が表示され exit 0

- [ ] **Step 2: CI に extension ジョブを追加**

`.github/workflows/ci.yml` の `jobs:` に追加(既存の `test`/`perf` はそのまま):

```yaml
  extension:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: extension
    steps:
      - uses: actions/checkout@v7
      - name: Install tools
        uses: jdx/mise-action@v4
      - name: Build WASM core
        run: zig build wasm
        working-directory: ${{ github.workspace }}
      - name: WASM golden (Node)
        run: node --test core/tests/
        working-directory: ${{ github.workspace }}
      - name: Install deps
        run: npm ci
      - name: WASM size budget
        run: npm run size
      - name: Typecheck
        run: npm run typecheck
      - name: Unit tests
        run: npm test
      - name: Build extension
        run: npm run build
      - name: Install Playwright browser
        run: npx playwright install --with-deps chromium
      - name: E2E smoke
        run: npm run e2e
```

- [ ] **Step 3: ローカルで CI 相当を通す**

Run(リポジトリルートで): `zig build test && zig build wasm && node --test core/tests/ && cd extension && npm run size && npm run typecheck && npm test && npm run build && npm run e2e`
Expected: すべて成功

- [ ] **Step 4: Commit & push して CI を確認**

```bash
git add extension/scripts/ .github/workflows/ci.yml
git commit -m "ci: add extension job with WASM golden and gzip size budget"
git push -u origin feat/phase2-chrome-extension
gh run watch
```

Expected: 3 ジョブ(test / perf / extension)すべて green

---

### Task 12: 手動検証(実ブラウザ)と仕上げ

**Files:**
- Modify: `docs/superpowers/specs/2026-07-03-prefablens-phase2-chrome-design.md`(ステータス行に実装計画へのリンク追記のみ)

**Interfaces:**
- Consumes: `extension/dist/`(全タスクの成果)
- Produces: 動作確認済みのブランチ(PR 作成は superpowers:finishing-a-development-branch に従う)

- [ ] **Step 1: 手動検証チェックリスト(人間の確認が必要 — 結果を待つこと)**

実行者へ: ここは自動化できない。ユーザーに以下を依頼し、結果を待つ。

1. `zig build wasm && cd extension && npm run build`
2. Chrome → `chrome://extensions` → デベロッパーモード → 「パッケージ化されていない拡張機能を読み込む」→ `extension/dist`
3. 拡張の Options で PAT(`repo` または `contents:read` 相当)を保存
4. `.prefab` / `.unity` / `.asset` を含む実 PR の Files changed を開く
5. 確認項目:
   - [ ] Unity ファイルの見出しに `[Raw | Semantic]` トグルが出る(他のファイルには出ない)
   - [ ] Semantic でツリーが描画され、Raw に戻せる
   - [ ] PR 内変更 `.meta` の guid がパスに解決される(未解決は生 guid)
   - [ ] dark モードで配色が追従する
   - [ ] PAT を消して Semantic → 「Set a GitHub token…」が表示される
   - [ ] DevTools コンソールにトークン・raw エラーが出ていない
   - [ ] ファイル追加/削除の PR でも動く(片側空)

見つかった問題は superpowers:systematic-debugging で潰してから次へ。

- [ ] **Step 2: 設計ドキュメントに計画リンクを追記**

`docs/superpowers/specs/2026-07-03-prefablens-phase2-chrome-design.md` 冒頭のステータス行を更新:

```markdown
> **ステータス:** 承認済み(2026-07-03)。実装計画: `docs/superpowers/plans/2026-07-03-prefablens-phase2-chrome-extension.md`
```

- [ ] **Step 3: 全体検証と Commit**

Run: `zig build test && zig build perf && zig build wasm && node --test core/tests/ && cd extension && npm run typecheck && npm test && npm run e2e`
Expected: すべて成功

```bash
git add docs/ && git commit -m "docs: link phase 2 implementation plan from design doc"
```

- [ ] **Step 4: ブランチ仕上げ**

superpowers:finishing-a-development-branch に従って PR 作成へ(main への PR。CI green を確認してからマージ)。

---

## Follow-up(このプランのスコープ外 — 設計書の延期リスト)

- Code Search API による guid 解決(`buildGuidIndex` の `MetaFetcher` seam に追加プロバイダとして差す)
- `repo + sha` キャッシュ(`handler.ts` の `contexts` Map を `chrome.storage.session` 等へ拡張)
- 25 MB 超のクリック描画ガード
- Playwright E2E の本格整備(実 PR ページ採取・拡張本体ロードでの E2E)
- GHES ドメインへの content script 動的登録と `chrome.permissions` リクエスト
- commit 比較・blob 単体ビュー、OAuth、Firefox/Edge 移植
