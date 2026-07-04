# PrefabLens Phase 4: MCP ホスト Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 既存 CLI をサブプロセスで叩く薄い MCP サーバ(`@hashiiiii/prefablens-mcp`)を `/mcp` に作り、コーディングエージェントが Unity アセットの意味的 diff を `prefab_diff` ツールで取れるようにする。

**Architecture:** stdio MCP サーバ(TypeScript)。git 調達・guid 解決・描画はすべて CLI 側で、MCP 層は「CLI の探索/自動取得 → サブプロセス実行 → 出力中継」のみ(spec: `docs/superpowers/specs/2026-07-04-phase4-mcp-host-design.md`)。CLI 取得は Editor `editor/Editor/Cli.cs` と同じ流儀の TS 版。

**Tech Stack:** Node 22 / TypeScript(strict + noUncheckedIndexedAccess)/ `@modelcontextprotocol/server`(サーバ)+ `@modelcontextprotocol/client`(テスト)/ zod v4 / fflate(zip 展開)/ vitest。

## Global Constraints

- パッケージ名 `@hashiiiii/prefablens-mcp`、version `0.1.0`。**`mcp/package.json` の version が唯一のソース**(= ダウンロードする CLI の Releases タグ `v<version>`)
- ランタイム依存は `@modelcontextprotocol/server` / `zod` / `fflate` の 3 つだけ。license フィールドは書かない(リポジトリに LICENSE なし、ユーザー判断待ち)
- import は SDK ドキュメント準拠: `@modelcontextprotocol/server`、`@modelcontextprotocol/server/stdio`、`import * as z from 'zod/v4'`
- tsc emit(NodeNext)なので相対 import は `./cli.js` のように **.js 拡張子必須**(extension の bundler 解決とは異なる)
- コミットは 1 行英語 ≤50 字(git-conventions)。ブランチは作成済みの `feat/mcp-host` を継続
- 検証コマンドを **パイプしない**(`cmd | tail` は exit code が化ける。Phase 2 の教訓)
- 各タスクの検証は `mcp/` で `npm run typecheck` と `npx vitest run <file>` を素で実行する

## File Structure

```
mcp/
  package.json          … name/version/bin/scripts(build, typecheck, test)
  tsconfig.json         … typecheck 用(src + vitest.config.ts、noEmit)
  tsconfig.build.json   … build 用(src のみ、テスト除外、dist へ emit)
  vitest.config.ts      … include src/**/*.test.ts、testTimeout 30s
  src/diff.ts           … buildArgs / truncateTree(純関数)
  src/cli.ts            … releaseAssetName / downloadUrl / binaryName / cachePath /
                          installFromZip / ensureCli / runCli
  src/index.ts          … bin エントリ(shebang)。serveStdio + prefab_diff 登録 + ハンドラ
  src/diff.test.ts      … 純関数の単体
  src/cli.test.ts       … 純関数 + installFromZip + runCli の単体
  src/server.test.ts    … 統合(fixture git repo + StdioClientTransport + ゴールデン)
```

CI/リリース側: `.github/workflows/ci.yml`(mcp ジョブ追加)、`.github/workflows/release.yml`(npm publish 追加)、`.claude/skills/cut-release/`(bump 対象 4→5 箇所)。

---

### Task 1: パッケージ骨格 + diff.ts 純関数

**Files:**
- Create: `mcp/package.json` / `mcp/tsconfig.json` / `mcp/tsconfig.build.json` / `mcp/vitest.config.ts` / `mcp/.gitignore`
- Create: `mcp/src/diff.ts`
- Test: `mcp/src/diff.test.ts`

**Interfaces:**
- Produces: `buildArgs(a: DiffArgs): string[]`(DiffArgs = `{ path: string; before: string; after?: string; format: 'tree' | 'json' }`)/ `truncateTree(text: string, limit?: number): string` / `TREE_CHAR_LIMIT = 50_000`。Task 4 のハンドラが両方を使う

- [ ] **Step 1: 骨格ファイルを書く**

`mcp/package.json`(依存は Step 2 の npm install が追記する):

```json
{
  "name": "@hashiiiii/prefablens-mcp",
  "version": "0.1.0",
  "description": "MCP server for semantic diffs of Unity YAML assets (.prefab/.unity/.asset)",
  "repository": {
    "type": "git",
    "url": "https://github.com/hashiiiii/PrefabLens.git",
    "directory": "mcp"
  },
  "type": "module",
  "bin": { "prefablens-mcp": "dist/index.js" },
  "files": ["dist"],
  "engines": { "node": ">=22" },
  "scripts": {
    "build": "tsc -p tsconfig.build.json",
    "typecheck": "tsc --noEmit",
    "test": "vitest run"
  }
}
```

`mcp/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "types": ["node"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src", "vitest.config.ts"]
}
```

`mcp/tsconfig.build.json`:

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": { "noEmit": false, "outDir": "dist" },
  "include": ["src"],
  "exclude": ["src/**/*.test.ts"]
}
```

`mcp/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { include: ['src/**/*.test.ts'], testTimeout: 30_000 },
});
```

`mcp/.gitignore`:

```
node_modules/
dist/
```

- [ ] **Step 2: 依存をインストール**

```bash
cd mcp
npm install @modelcontextprotocol/server zod fflate
npm install -D @modelcontextprotocol/client typescript vitest @types/node
```

インストール後、`node -p "require('@modelcontextprotocol/server/package.json').version"` でサーバ SDK が解決できることを確認(SDK のパッケージ名が異なる場合はここで発覚する。その場合は公式 README に従い読み替えて、以降のタスクの import も同じ名前に揃える)。

- [ ] **Step 3: 失敗するテストを書く**

`mcp/src/diff.test.ts`:

```ts
import { expect, test } from 'vitest';
import { buildArgs, truncateTree } from './diff.js';

test('buildArgs: tree + working-tree comparison', () => {
  expect(buildArgs({ path: 'A.prefab', before: 'HEAD', format: 'tree' })).toEqual([
    '--no-color', '--project', '.', '--git', 'HEAD', 'A.prefab',
  ]);
});

test('buildArgs: json + two refs', () => {
  expect(buildArgs({ path: 'A.prefab', before: 'main', after: 'HEAD', format: 'json' })).toEqual([
    '--json', '--project', '.', '--git', 'main', 'HEAD', 'A.prefab',
  ]);
});

test('truncateTree passes short text through', () => {
  expect(truncateTree('short')).toBe('short');
});

test('truncateTree truncates long text and appends a note', () => {
  const out = truncateTree('x'.repeat(60_000));
  expect(out.startsWith('x'.repeat(100))).toBe(true);
  expect(out.length).toBeLessThan(50_100);
  expect(out).toContain('[truncated: 60000 chars total]');
});
```

- [ ] **Step 4: 落ちることを確認**

Run: `cd mcp && npx vitest run src/diff.test.ts`
Expected: FAIL(`./diff.js` が存在しない)

- [ ] **Step 5: 実装**

`mcp/src/diff.ts`:

```ts
export const TREE_CHAR_LIMIT = 50_000;

export interface DiffArgs {
  path: string;
  before: string;
  after?: string;
  format: 'tree' | 'json';
}

/** CLI 引数を組み立てる。--project . で cwd(= projectRoot)起点の .meta 走査による guid 解決を効かせる。 */
export function buildArgs(a: DiffArgs): string[] {
  const flags = a.format === 'json' ? ['--json'] : ['--no-color'];
  const refs = a.after === undefined ? [a.before] : [a.before, a.after];
  return [...flags, '--project', '.', '--git', ...refs, a.path];
}

/** LLM コンテキスト保護。tree 出力のみ対象(json は機械処理用途なので呼び出し側が使わない)。 */
export function truncateTree(text: string, limit = TREE_CHAR_LIMIT): string {
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}\n[truncated: ${text.length} chars total]\n`;
}
```

- [ ] **Step 6: 通ることを確認**

Run: `cd mcp && npx vitest run src/diff.test.ts`
Expected: PASS(4 tests)

Run: `cd mcp && npm run typecheck`
Expected: エラーなし

- [ ] **Step 7: Commit**

```bash
git add mcp
git commit -m "feat: scaffold mcp package with diff args"
```

---

### Task 2: cli.ts — 探索・取得・実行

**Files:**
- Create: `mcp/src/cli.ts`
- Test: `mcp/src/cli.test.ts`

**Interfaces:**
- Produces(Task 4 のハンドラと Task 3 の統合テストが使う):
  - `releaseAssetName(platform: NodeJS.Platform, arch: string): string`
  - `downloadUrl(version: string, assetName: string): string`
  - `binaryName(platform: NodeJS.Platform): string`
  - `cachePath(version: string, platform: NodeJS.Platform, home: string): string`
  - `installFromZip(zipBytes: Uint8Array, dest: string, platform: NodeJS.Platform): void`
  - `ensureCli(version: string): Promise<string>`(env `PREFABLENS_CLI` → キャッシュ → ダウンロード。戻り値は実行パス)
  - `runCli(cliPath: string, args: string[], cwd: string): Promise<CliResult>`(CliResult = `{ code: number; stdout: string; stderr: string }`)

- [ ] **Step 1: 失敗するテストを書く**

`mcp/src/cli.test.ts`:

```ts
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { zipSync } from 'fflate';
import { afterAll, expect, test } from 'vitest';
import { binaryName, cachePath, downloadUrl, installFromZip, releaseAssetName, runCli } from './cli.js';

const dir = mkdtempSync(path.join(tmpdir(), 'prefablens-cli-test-'));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

test('releaseAssetName maps platform/arch to the four release zips', () => {
  expect(releaseAssetName('win32', 'x64')).toBe('prefablens-windows-x64.zip');
  expect(releaseAssetName('darwin', 'arm64')).toBe('prefablens-macos-arm64.zip');
  expect(releaseAssetName('darwin', 'x64')).toBe('prefablens-macos-x64.zip');
  expect(releaseAssetName('linux', 'x64')).toBe('prefablens-linux-x64.zip');
});

test('downloadUrl points at the tagged GitHub release', () => {
  expect(downloadUrl('0.1.0', 'prefablens-macos-arm64.zip')).toBe(
    'https://github.com/hashiiiii/PrefabLens/releases/download/v0.1.0/prefablens-macos-arm64.zip',
  );
});

test('binaryName appends .exe only on windows', () => {
  expect(binaryName('win32')).toBe('prefablens.exe');
  expect(binaryName('darwin')).toBe('prefablens');
});

test('cachePath is versioned under <home>/.cache/prefablens', () => {
  expect(cachePath('0.1.0', 'linux', '/home/u')).toBe(
    path.join('/home/u', '.cache', 'prefablens', '0.1.0', 'prefablens'),
  );
});

test('installFromZip extracts the binary atomically and marks it executable', () => {
  const zip = zipSync({ prefablens: new TextEncoder().encode('#!/bin/sh\necho ok\n') });
  const dest = path.join(dir, 'v1', 'prefablens');
  installFromZip(zip, dest, 'linux');
  expect(readFileSync(dest, 'utf8')).toContain('echo ok');
  expect(statSync(dest).mode & 0o111).not.toBe(0);
});

test('installFromZip rejects a zip without the expected binary', () => {
  const zip = zipSync({ other: new Uint8Array([1]) });
  expect(() => installFromZip(zip, path.join(dir, 'v2', 'prefablens'), 'linux')).toThrow('not found');
});

test('runCli captures stdout and exit code', async () => {
  const res = await runCli('git', ['--version'], process.cwd());
  expect(res.code).toBe(0);
  expect(res.stdout).toContain('git version');
});
```

- [ ] **Step 2: 落ちることを確認**

Run: `cd mcp && npx vitest run src/cli.test.ts`
Expected: FAIL(`./cli.js` が存在しない)

- [ ] **Step 3: 実装**

`mcp/src/cli.ts`:

```ts
import { spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { unzipSync } from 'fflate';

/** Editor の Cli.ReleaseAssetName と同じ対応表(release.yml のアセット 4 種)。 */
export function releaseAssetName(platform: NodeJS.Platform, arch: string): string {
  if (platform === 'win32') return 'prefablens-windows-x64.zip';
  if (platform === 'darwin') return arch === 'arm64' ? 'prefablens-macos-arm64.zip' : 'prefablens-macos-x64.zip';
  return 'prefablens-linux-x64.zip';
}

export function downloadUrl(version: string, assetName: string): string {
  return `https://github.com/hashiiiii/PrefabLens/releases/download/v${version}/${assetName}`;
}

export function binaryName(platform: NodeJS.Platform): string {
  return platform === 'win32' ? 'prefablens.exe' : 'prefablens';
}

export function cachePath(version: string, platform: NodeJS.Platform, home: string): string {
  return path.join(home, '.cache', 'prefablens', version, binaryName(platform));
}

/** temp に書いて rename する原子的配置。同時起動の二重ダウンロードは後勝ちで無害。 */
export function installFromZip(zipBytes: Uint8Array, dest: string, platform: NodeJS.Platform): void {
  const body = unzipSync(zipBytes)[binaryName(platform)];
  if (body === undefined) throw new Error(`${binaryName(platform)} not found in release zip`);
  mkdirSync(path.dirname(dest), { recursive: true });
  const tmp = `${dest}.tmp-${process.pid}`;
  writeFileSync(tmp, body);
  if (platform !== 'win32') chmodSync(tmp, 0o755);
  renameSync(tmp, dest);
}

/** env PREFABLENS_CLI → キャッシュ → GitHub Releases の順で CLI を確保する。 */
export async function ensureCli(version: string): Promise<string> {
  const manual = process.env['PREFABLENS_CLI'];
  if (manual !== undefined && manual !== '' && existsSync(manual)) return manual;
  const dest = cachePath(version, process.platform, homedir());
  if (existsSync(dest)) return dest;
  const url = downloadUrl(version, releaseAssetName(process.platform, process.arch));
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download failed: HTTP ${res.status} for ${url}`);
  installFromZip(new Uint8Array(await res.arrayBuffer()), dest, process.platform);
  return dest;
}

export interface CliResult {
  code: number;
  stdout: string;
  stderr: string;
}

export function runCli(cliPath: string, args: string[], cwd: string): Promise<CliResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(cliPath, args, { cwd });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c: Buffer) => { stdout += c; });
    child.stderr.on('data', (c: Buffer) => { stderr += c; });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}
```

ダウンロード実路(fetch 分岐)はネットワーク依存のため単体テストしない(env 注入経路は Task 3 の統合テストが通す)。

- [ ] **Step 4: 通ることを確認**

Run: `cd mcp && npx vitest run src/cli.test.ts`
Expected: PASS(7 tests)

Run: `cd mcp && npm run typecheck`
Expected: エラーなし

- [ ] **Step 5: Commit**

```bash
git add mcp/src/cli.ts mcp/src/cli.test.ts
git commit -m "feat: locate download and run cli from mcp"
```

---

### Task 3: index.ts サーバ本体 + 統合テスト

**Files:**
- Create: `mcp/src/index.ts`
- Test: `mcp/src/server.test.ts`

**Interfaces:**
- Consumes: Task 1 の `buildArgs`/`truncateTree`、Task 2 の `ensureCli`/`runCli`
- Produces: MCP ツール `prefab_diff`(引数 `path`/`before`(既定 HEAD)/`after`/`projectRoot`/`format`(tree|json))。bin `prefablens-mcp` → `dist/index.js`

- [ ] **Step 1: 失敗する統合テストを書く**

`mcp/src/server.test.ts`(fixture は既存の `core/src/testdata/plane_*.prefab` を temp git リポジトリにコピーして使う。サーバはビルド済み `dist/index.js` を Node 子プロセスで起動し、`PREFABLENS_CLI` でローカルビルドの CLI を注入するためネットワーク非依存):

```ts
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { afterAll, beforeAll, expect, test } from 'vitest';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const cliPath = path.join(repoRoot, 'zig-out', 'bin', process.platform === 'win32' ? 'prefablens.exe' : 'prefablens');
const serverEntry = fileURLToPath(new URL('../dist/index.js', import.meta.url));
const testdata = path.join(repoRoot, 'core', 'src', 'testdata');

let fixtureRepo: string;
let client: Client;

function git(cwd: string, ...args: string[]): void {
  execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd });
}

function firstText(res: { content?: unknown }): string {
  const content = res.content as { type: string; text: string }[];
  return content[0]?.text ?? '';
}

beforeAll(async () => {
  fixtureRepo = mkdtempSync(path.join(tmpdir(), 'prefablens-mcp-'));
  cpSync(path.join(testdata, 'plane_before.prefab'), path.join(fixtureRepo, 'Plane.prefab'));
  git(fixtureRepo, 'init', '-q');
  git(fixtureRepo, 'add', '.');
  git(fixtureRepo, 'commit', '-q', '-m', 'init');
  cpSync(path.join(testdata, 'plane_after.prefab'), path.join(fixtureRepo, 'Plane.prefab'));

  client = new Client({ name: 'test', version: '0.0.0' });
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    env: { PREFABLENS_CLI: cliPath, PATH: process.env['PATH'] ?? '' },
  }));
});

afterAll(async () => {
  await client.close();
  rmSync(fixtureRepo, { recursive: true, force: true });
});

test('prefab_diff returns the semantic tree for HEAD vs working tree', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', projectRoot: fixtureRepo },
  });
  expect(res.isError).toBeFalsy();
  // ゴールデン。実装後に実出力を目視確認してからピンする(既存 golden の流儀)。
  expect(firstText(res)).toBe([
    '  Plane',
    '  ~ Cylinder  <Prefab>',
    '      components',
    '        ~ Transform',
    '          ~ Position.x: 0.41646004 -> 1',
    '  + Cylinder Variant  <Prefab>',
    '      components',
    '        + Transform',
    '          + Position: (2.03, 3.63, 1.11797)',
    '',
  ].join('\n'));
});

test('prefab_diff format:"json" returns prefablens.diff.v2', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', projectRoot: fixtureRepo, format: 'json' },
  });
  expect(res.isError).toBeFalsy();
  const parsed = JSON.parse(firstText(res)) as { schema: string };
  expect(parsed.schema).toBe('prefablens.diff.v2');
});

test('prefab_diff surfaces cli errors as tool errors', async () => {
  const res = await client.callTool({
    name: 'prefab_diff',
    arguments: { path: 'Plane.prefab', before: 'nosuchref', after: 'HEAD', projectRoot: fixtureRepo },
  });
  expect(res.isError).toBe(true);
  expect(firstText(res)).toContain("git show failed for 'nosuchref:Plane.prefab'");
});
```

- [ ] **Step 2: 落ちることを確認**

Run(リポジトリルートで CLI を先にビルド): `zig build`
Run: `cd mcp && npm run build`
Expected: build が `src/index.ts` 不在で FAIL(または dist/index.js 不在でテスト FAIL)

- [ ] **Step 3: 実装**

`mcp/src/index.ts`:

```ts
#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import { ensureCli, runCli } from './cli.js';
import { buildArgs, truncateTree } from './diff.js';

/** npm version = ダウンロードする CLI の Releases タグ(spec のバージョン規約)。 */
const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string };

const DESCRIPTION =
  'Semantic diff for Unity YAML assets (.prefab/.unity/.asset) between two git versions. ' +
  'Use this instead of reading raw YAML diffs: it matches objects by fileID and reports ' +
  'added/removed/modified GameObjects, components, fields, and prefab overrides with resolved names.';

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

serveStdio(() => {
  const server = new McpServer({ name: 'prefablens', version: pkg.version });

  server.registerTool(
    'prefab_diff',
    {
      description: DESCRIPTION,
      inputSchema: z.object({
        path: z.string().describe('Asset path (.prefab/.unity/.asset), relative to projectRoot'),
        before: z.string().default('HEAD').describe('Base git ref'),
        after: z.string().optional().describe('Target git ref; omit to compare against the working tree'),
        projectRoot: z.string().optional().describe('Repository root; defaults to the server cwd'),
        format: z.enum(['tree', 'json']).default('tree').describe('tree = readable text, json = prefablens.diff.v2'),
      }),
    },
    async ({ path: assetPath, before, after, projectRoot, format }) => {
      try {
        const cli = await ensureCli(pkg.version).catch((e: unknown) => {
          throw new Error(
            `prefablens CLI unavailable: ${message(e)}\n` +
            'Place the binary manually and set PREFABLENS_CLI to its path.',
          );
        });
        const res = await runCli(cli, buildArgs({ path: assetPath, before, after, format }), projectRoot ?? process.cwd());
        if (res.code !== 0) {
          return {
            content: [{ type: 'text' as const, text: res.stderr.trim() || `prefablens exited with code ${res.code}` }],
            isError: true,
          };
        }
        const text = format === 'tree' ? truncateTree(res.stdout) : res.stdout;
        return { content: [{ type: 'text' as const, text }] };
      } catch (e) {
        return { content: [{ type: 'text' as const, text: message(e) }], isError: true };
      }
    },
  );

  return server;
});
```

- [ ] **Step 4: ビルドして統合テストを通す**

Run: `cd mcp && npm run typecheck`
Expected: エラーなし

Run: `cd mcp && npm run build`
Expected: `dist/index.js` 生成(1 行目に shebang が残ることを確認)

Run: `cd mcp && npx vitest run src/server.test.ts`
Expected: PASS(3 tests)。tree ゴールデンが実出力と食い違ったら、`format:"tree"` の実出力を目視で妥当確認した上でテスト側をピンし直す(末尾改行の有無に注意)

- [ ] **Step 5: 全テスト + Commit**

Run: `cd mcp && npm test`
Expected: PASS(diff 4 + cli 7 + server 3 = 14 tests)

```bash
git add mcp/src/index.ts mcp/src/server.test.ts
git commit -m "feat: add prefab_diff mcp server"
```

---

### Task 4: CI ジョブ + リリースパイプライン + cut-release 更新

**Files:**
- Modify: `.github/workflows/ci.yml`(mcp ジョブ追加)
- Modify: `.github/workflows/release.yml`(permissions + npm publish ステップ追加)
- Modify: `.claude/skills/cut-release/scripts/check-versions.sh`(5 箇所目を追加)
- Modify: `.claude/skills/cut-release/SKILL.md`(コンポーネント数・bump 対象の記述更新)

**Interfaces:**
- Consumes: Task 1-3 の `mcp/` パッケージ(scripts: typecheck / build / test)
- Produces: tag `v*` push で「zip アセット公開 → npm publish」が 1 job 内でこの順に走る

- [ ] **Step 1: ci.yml に mcp ジョブを追加**

既存 `extension` ジョブの後に追記(同じ流儀: mise で zig/node を入れ、CLI を先にビルドして統合テストに使わせる):

```yaml
  mcp:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: mcp
    steps:
      - uses: actions/checkout@v7
      - name: Install tools
        uses: jdx/mise-action@v4
      - name: Build CLI
        run: zig build
        working-directory: ${{ github.workspace }}
      - name: Install deps
        run: npm ci
      - name: Typecheck
        run: npm run typecheck
      - name: Build
        run: npm run build
      - name: Tests
        run: npm test
```

- [ ] **Step 2: release.yml に npm publish を追加**

`permissions:` ブロックを更新(Trusted Publishing の OIDC トークン用):

```yaml
permissions:
  contents: write
  id-token: write
```

`Create release` ステップの **後** に追記(npm が参照する CLI タグの Releases が先に存在する順序制約):

```yaml
      - name: Publish MCP server to npm
        working-directory: mcp
        run: |
          set -euo pipefail
          version=$(node -p "require('./package.json').version")
          if [ "v$version" != "$GITHUB_REF_NAME" ]; then
            echo "mcp/package.json version $version does not match tag $GITHUB_REF_NAME" >&2
            exit 1
          fi
          npm install -g npm@latest  # trusted publishing は npm >= 11.5.1 が必要(node 22 同梱は 10.x)
          npm ci
          npm run build
          npm publish --access public
```

- [ ] **Step 3: check-versions.sh に mcp を追加**

`xman=` の行の下に追加:

```bash
mpkg=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' mcp/package.json | head -1)
```

`check "extension/manifest.json"` の行の下に追加:

```bash
check "mcp/package.json"          "$mpkg"
```

末尾のメッセージと冒頭コメントの「four」を「five」に更新:

```bash
echo "all five version sources at $want"
```

Run: `.claude/skills/cut-release/scripts/check-versions.sh 0.1.0`
Expected: 5 行すべて `ok`(現行は全ソース 0.1.0 のため)

- [ ] **Step 4: cut-release SKILL.md を更新**

- description の「Bumps the four version sources」→「Bumps the five version sources」
- Overview の「ships three components on one version line: the Zig CLI, the Chrome extension, and the Unity Editor package」→「ships four components on one version line: the Zig CLI, the Chrome extension, the Unity Editor package, and the MCP server (npm)」
- Steps 2 の bump リストに追加: `mcp/package.json` → `"version": "X.Y.Z"`
- リリース自動化の説明に追記: 「release workflow は zip アセット公開後に `@hashiiiii/prefablens-mcp` を npm publish する(Trusted Publishing。npmjs.com 側の設定が初回 publish 前に必要)」
- Steps 6 の検証に追加: `npm view @hashiiiii/prefablens-mcp version` がタグと一致すること

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml .claude/skills/cut-release
git commit -m "ci: build test and publish mcp package"
```

---

### Task 5: 全体検証 + PR 作成

**Files:** なし(検証のみ)

- [ ] **Step 1: フレッシュ全検証**(パイプ禁止・各コマンドの exit code をそのまま見る)

```bash
zig build test
zig build
cd mcp
npm ci
npm run typecheck
npm run build
npm test
cd ..
.claude/skills/cut-release/scripts/check-versions.sh 0.1.0
```

Expected: すべて成功(zig test 96+ / mcp 14 tests / check-versions 5 ok)

- [ ] **Step 2: 実機スモーク**(MCP クライアントとしての目視確認)

```bash
cd mcp
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | PREFABLENS_CLI=../zig-out/bin/prefablens node dist/index.js
```

Expected: `tools/list` 応答に `prefab_diff` が含まれる(JSON-RPC 生ログの目視。プロトコルバージョン文字列は SDK が違うものを要求したらエラーメッセージに従って合わせる)

- [ ] **Step 3: push + PR 作成**

```bash
git push -u origin feat/mcp-host
gh pr create --title "feat: MCP host exposing prefab_diff tool" --body "..."
```

PR body には以下を含める: spec/plan へのリンク / 検証結果 / **マージ前のユーザー作業 2 点**(npmjs.com で `@hashiiiii/prefablens-mcp` の Trusted Publisher を release.yml に対して設定する / license フィールド未設定の判断)。機能本体につき **マージはユーザー確認**([[workflow-autonomy]] の自己マージ対象外)

- [ ] **Step 4: CI green を確認**

Run: `gh run watch $(gh run list --branch feat/mcp-host --limit 1 --json databaseId -q '.[0].databaseId')`
Expected: test / perf / extension / mcp の 4 ジョブすべて成功
