/// <reference types="node" />
import { expect, test, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';

const fixture = readFileSync(new URL('./fixtures/pr-files.html', import.meta.url), 'utf8');

// content script は起動時に chrome.storage.local から viewMode を読む。
// スタブに storage が無いと init が落ちて全テストが壊れるため、必ず与える。
function stubChrome(page: Page, res: unknown, viewMode?: string) {
  return page.addInitScript(
    ({ res, viewMode }) => {
      (window as unknown as Record<string, unknown>)['chrome'] = {
        runtime: {
          sendMessage: (msg: { type?: string }) =>
            msg?.type === 'semanticDiff' ? Promise.resolve(res) : Promise.resolve(),
          onMessage: { addListener: () => {} },
        },
        storage: {
          local: {
            get: () => Promise.resolve(viewMode ? { viewMode } : {}),
            set: () => Promise.resolve(),
          },
          onChanged: { addListener: () => {} },
        },
      };
    },
    { res, viewMode },
  );
}

const cannedResponse = {
  ok: true,
  json: {
    schema: 'prefablens.diff.v2',
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
        className: null,
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
  await stubChrome(page, cannedResponse);

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

test('sends a prefetch message on pr page arrival', async ({ page }) => {
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  await stubChrome(page, cannedResponse);
  // stubChrome の sendMessage を包んで記録する
  await page.addInitScript(() => {
    const w = window as unknown as { chrome: { runtime: { sendMessage: (m: unknown) => Promise<unknown> } }; __sent: unknown[] };
    w.__sent = [];
    const orig = w.chrome.runtime.sendMessage;
    w.chrome.runtime.sendMessage = (m: unknown) => {
      w.__sent.push(m);
      return orig(m);
    };
  });
  await page.goto('https://prefablens.test/owner/repo/pull/1/files');
  await page.addScriptTag({ path: 'dist/content.js' });
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { __sent: Array<{ type?: string }> }).__sent.filter((m) => m?.type === 'prefetch').length))
    .toBe(1); // 同一 PR では 1 回だけ
});

test('attaches toggles to files added after the initial scan (SPA lazy loading)', async ({ page }) => {
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  await stubChrome(page, cannedResponse);

  await page.goto('https://prefablens.test/owner/repo/pull/1/files');
  await page.addScriptTag({ path: 'dist/content.js' });

  // GitHub は Files changed をスクロールで遅延ロードする: 初回スキャン後の追加を MutationObserver が拾う
  await page.evaluate(() => {
    const file = document.createElement('div');
    file.className = 'file';
    file.innerHTML =
      '<div class="file-header" data-path="Assets/Late.prefab"></div><div class="js-file-content">raw diff</div>';
    document.body.append(file);
  });
  const lateHeader = page.locator('.file-header[data-path="Assets/Late.prefab"]');
  await expect(lateHeader.getByRole('button', { name: 'Semantic' })).toBeVisible();
});

test('recovers after an error response', async ({ page }) => {
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  // 1回目は pat-missing エラー、2回目以降は正常応答を返す(エラーはキャッシュされず再フェッチされることを確認)
  // カウンタ用に専用スタブを使うが、init が落ちないよう storage/onMessage は stubChrome と同じ形にする
  await page.addInitScript((res) => {
    (window as unknown as Record<string, unknown>)['__prefablensCalls'] = 0;
    (window as unknown as Record<string, unknown>)['chrome'] = {
      runtime: {
        // prefetch はカウント対象外にする: attach() が pull ページ到達時に必ず 1 通送るため、
        // 素朴な全件カウントだと 1 回目の semanticDiff がずれてエラー→成功の検証が壊れる
        sendMessage: (msg: { type?: string }) => {
          if (msg?.type !== 'semanticDiff') return Promise.resolve();
          const w = window as unknown as Record<string, number>;
          const call = w['__prefablensCalls']!;
          w['__prefablensCalls'] = call + 1;
          return Promise.resolve(call === 0 ? { ok: false, error: 'pat-missing' } : res);
        },
        onMessage: { addListener: () => {} },
      },
      storage: {
        local: {
          get: () => Promise.resolve({}),
          set: () => Promise.resolve(),
        },
        onChanged: { addListener: () => {} },
      },
    };
  }, cannedResponse);

  await page.goto('https://prefablens.test/owner/repo/pull/1/files');
  await page.addScriptTag({ path: 'dist/content.js' });

  const unityHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  const view = page.locator('[data-prefablens-view]');

  // 1回目のトグル: エラー表示
  await unityHeader.getByRole('button', { name: 'Semantic' }).click();
  await expect(view).toContainText('Set a GitHub token');

  // Raw → Semantic と再トグルすると再フェッチされ、正常結果に回復する
  await unityHeader.getByRole('button', { name: 'Raw' }).click();
  await unityHeader.getByRole('button', { name: 'Semantic' }).click();
  await expect(view).toContainText('MonoBehaviour');
});

test('applies the persisted semantic default to every unity file and late additions', async ({ page }) => {
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  await stubChrome(page, cannedResponse, 'semantic'); // 前回の選択が semantic で保存済み

  await page.goto('https://prefablens.test/owner/repo/pull/1/files');
  await page.addScriptTag({ path: 'dist/content.js' });

  // クリックなしで両方の Unity ファイルが semantic 描画になっている
  await expect(page.locator('[data-prefablens-view]')).toHaveCount(2);
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();

  // 全体トグルも既定を反映して Semantic 押下状態で現れる
  const global = page.locator('[data-prefablens-global]');
  await expect(global.locator('button[data-view="semantic"]')).toHaveAttribute('aria-pressed', 'true');

  // 遅延ロードで現れたファイルも既定を継承する(「押したのに raw」が起きない核心)
  await page.evaluate(() => {
    const file = document.createElement('div');
    file.className = 'file';
    file.innerHTML =
      '<div class="file-header" data-path="Assets/Late.prefab"></div><div class="js-file-content">raw diff</div>';
    document.body.append(file);
  });
  await expect(page.locator('[data-prefablens-view]')).toHaveCount(3);
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Late.prefab"]) .js-file-content')).toBeHidden();
});

test('global toggle switches all files and resets per-file overrides', async ({ page }) => {
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  await stubChrome(page, cannedResponse);

  await page.goto('https://prefablens.test/owner/repo/pull/1/files');
  await page.addScriptTag({ path: 'dist/content.js' });

  // 全体トグルは最初の Unity ファイルの直前に 1 つだけ注入される
  const global = page.locator('[data-prefablens-global]');
  await expect(global).toHaveCount(1);

  // 位置契約: バーは最初の Unity ファイルの .file コンテナ直前に入る
  await expect(page.locator('[data-prefablens-global] + .file .file-header[data-path="Assets/Foo.prefab"]')).toHaveCount(1);

  // 全体 Semantic → 全 Unity ファイルが切り替わる(README は対象外)
  await global.getByRole('button', { name: 'Semantic' }).click();
  await expect(page.locator('[data-prefablens-view]')).toHaveCount(2);

  // 個別に Raw へ上書き → そのファイルだけ raw に戻る
  const fooHeader = page.locator('.file-header[data-path="Assets/Foo.prefab"]');
  await fooHeader.getByRole('button', { name: 'Raw' }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeVisible();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Big.unity"]) .js-file-content')).toBeHidden();

  // 全体 Raw → Semantic と操作すると上書きがリセットされ、必ず全ファイルが揃う
  await global.getByRole('button', { name: 'Raw' }).click();
  await global.getByRole('button', { name: 'Semantic' }).click();
  await expect(page.locator('.file:has(.file-header[data-path="Assets/Foo.prefab"]) .js-file-content')).toBeHidden();
});
