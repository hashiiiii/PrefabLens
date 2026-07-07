/// <reference types="node" />
// 本物の拡張(--load-extension)で 検出 → 実 background → 実 WASM → 描画 を端から端まで通す。
// ローカル HTTP サーバを A1 の GHES 動的登録経由で「GitHub」として使う(--e2e build が 127.0.0.1 を事前許可)。
import { chromium, expect, test, type BrowserContext } from '@playwright/test';
import { createServer, type Server } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const DIST = fileURLToPath(new URL('../dist', import.meta.url));
const fixture = readFileSync(new URL('./fixtures/pr-files.html', import.meta.url), 'utf8');

// core/tests/wasm_golden.test.mjs と同じミニマル prefab: 出力が golden で確定している
const BEFORE = `--- !u!114 &11400000
MonoBehaviour:
  m_Script: {fileID: 0, guid: def, type: 3}
  volume: 0.5
`;
const AFTER = BEFORE.replace('0.5', '0.8');
// ドキュメントなしの 26MB = 25MB ガードを踏み、force 後は空 diff で軽く終わる
const BIG = 'x'.repeat(26 * 1024 * 1024);

function startServer(): Promise<{ server: Server; port: number }> {
  const server = createServer((req, res) => {
    const url = new URL(req.url!, 'http://127.0.0.1');
    const send = (body: string, type: string): void => {
      res.writeHead(200, { 'content-type': type });
      res.end(body);
    };
    const json = (body: unknown): void => send(JSON.stringify(body), 'application/json');
    switch (url.pathname) {
      case '/o/r/pull/1/files':
        return send(fixture, 'text/html');
      case '/api/v3/repos/o/r/pulls/1/files':
        return json([
          { filename: 'Assets/Foo.prefab', status: 'modified' },
          { filename: 'Assets/Big.unity', status: 'modified' },
        ]);
      case '/api/v3/repos/o/r/pulls/1':
        return json({ base: { sha: 'B' }, head: { sha: 'H' } });
      case '/api/v3/repos/o/r/compare/B...H':
        return json({ merge_base_commit: { sha: 'MB' } });
      case '/api/v3/repos/o/r/git/trees/H':
        return json({ truncated: false, tree: [] });
      case '/api/v3/repos/o/r/contents/Assets/Foo.prefab':
        return send(url.searchParams.get('ref') === 'MB' ? BEFORE : AFTER, 'application/vnd.github.raw+json');
      case '/api/v3/repos/o/r/contents/Assets/Big.unity':
        return send(BIG, 'application/vnd.github.raw+json');
      case '/api/v3/search/code':
        return json({ items: [{ path: 'Assets/Scripts/Sound.cs.meta' }] });
      default:
        res.writeHead(404);
        res.end();
    }
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({ server, port: (server.address() as { port: number }).port });
    });
  });
}

let context: BrowserContext;
let server: Server;
let port: number;

test.beforeAll(async () => {
  ({ server, port } = await startServer());
  context = await chromium.launchPersistentContext('', {
    channel: 'chromium', // headless で拡張を使うには chromium channel が必要
    args: [`--disable-extensions-except=${DIST}`, `--load-extension=${DIST}`],
  });
  let sw = context.serviceWorkers()[0];
  sw ??= await context.waitForEvent('serviceworker');
  const extensionId = new URL(sw.url()).host;

  // Options で PAT とローカルサーバを保存 → applyGhes が 127.0.0.1 を動的登録する
  const options = await context.newPage();
  await options.goto(`chrome-extension://${extensionId}/options.html`);
  await options.fill('#pat', 'tok');
  await options.fill('#baseUrl', `http://127.0.0.1:${port}`);
  await options.click('#save');
  await expect(options.locator('#status')).toHaveText('Saved');
  await options.close();
});

test.afterAll(async () => {
  await context?.close();
  server?.close();
});

test('renders a real wasm diff with code-search guid resolution', async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${port}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await header.getByRole('button', { name: 'Semantic' }).click();

  const view = page.locator('[data-prefablens-view]');
  // Code Search 経由で guid def → Sound.cs に実名解決され、型名ではなくスクリプト名が出る
  await expect(view).toContainText('Sound');
  await expect(view).toContainText('Volume');
  await expect(view).toContainText('0.5');
  await expect(view).toContainText('0.8');
  await page.close();
});

test('gates oversized files behind an explicit render click', async () => {
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${port}/o/r/pull/1/files`);

  const header = page.locator('.file-header[data-path="Assets/Big.unity"]');
  await header.getByRole('button', { name: 'Semantic' }).click();

  const view = page.locator('[data-prefablens-view]');
  await expect(view).toContainText('Large file (52 MB)', { timeout: 30_000 });
  await view.getByRole('button', { name: 'Render anyway' }).click();
  await expect(view).toContainText('No semantic changes', { timeout: 30_000 });
  await page.close();
});
