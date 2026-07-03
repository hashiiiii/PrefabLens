/// <reference types="node" />
import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';

const fixture = readFileSync(new URL('./fixtures/pr-files.html', import.meta.url), 'utf8');

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

test('recovers after an error response', async ({ page }) => {
  await page.route('**/pull/1/files', (route) => route.fulfill({ body: fixture, contentType: 'text/html' }));
  // 1回目は pat-missing エラー、2回目以降は正常応答を返す(エラーはキャッシュされず再フェッチされることを確認)
  await page.addInitScript((res) => {
    (window as unknown as Record<string, unknown>)['__prefablensCalls'] = 0;
    (window as unknown as Record<string, unknown>)['chrome'] = {
      runtime: {
        sendMessage: () => {
          const w = window as unknown as Record<string, number>;
          const call = w['__prefablensCalls']!;
          w['__prefablensCalls'] = call + 1;
          return Promise.resolve(call === 0 ? { ok: false, error: 'pat-missing' } : res);
        },
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
