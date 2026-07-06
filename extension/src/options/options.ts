import { applyGhes, type ChromeGhes } from './ghes';

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

export async function initOptions(doc: Document, storage: StorageLike, ghes?: ChromeGhes): Promise<void> {
  const pat = doc.querySelector<HTMLInputElement>('#pat')!;
  const baseUrl = doc.querySelector<HTMLInputElement>('#baseUrl')!;
  const status = doc.querySelector<HTMLElement>('#status')!;

  const stored = await storage.get(['pat', 'baseUrl']);
  pat.value = (stored['pat'] as string | undefined) ?? '';
  baseUrl.value = (stored['baseUrl'] as string | undefined) ?? '';

  doc.querySelector<HTMLButtonElement>('#save')!.addEventListener('click', () => {
    void (async () => {
      // 保存が最優先: GHES 登録の失敗で設定(特に PAT)を捨てない
      await storage.set({ pat: pat.value.trim(), baseUrl: baseUrl.value.trim() });
      const grant = ghes ? await applyGhes(baseUrl.value.trim(), ghes).catch(() => 'failed' as const) : 'ok';
      status.textContent =
        grant === 'ok' ? 'Saved' : grant === 'declined' ? 'Saved (host permission declined)' : 'Saved (GHES setup failed)';
    })().catch(() => {
      status.textContent = 'Save failed'; // ここに来るのは storage 失敗のみ
    });
  });
}

if (typeof chrome !== 'undefined' && chrome.storage) {
  document.body.innerHTML = OPTIONS_BODY;
  void initOptions(document, chrome.storage.local, chrome);
}
