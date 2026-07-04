// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest';
import { OPTIONS_BODY, initOptions } from './options';
import type { ChromeGhes } from './ghes';

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

  it('applies ghes registration with the trimmed base url on save', async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const ghes: ChromeGhes = {
      permissions: { request: vi.fn(async () => true) },
      scripting: {
        registerContentScripts: vi.fn(async () => {}),
        unregisterContentScripts: vi.fn(async () => {}),
      },
    };
    await initOptions(document, fakeStorage(), ghes);
    document.querySelector<HTMLInputElement>('#baseUrl')!.value = '  ghe.corp.com  ';
    document.querySelector<HTMLButtonElement>('#save')!.click();
    await new Promise((r) => setTimeout(r, 0));
    expect(ghes.permissions.request).toHaveBeenCalledWith({ origins: ['https://ghe.corp.com/*'] });
    expect(document.querySelector('#status')!.textContent).toBe('Saved');
  });

  it('saves but reports when the host permission is declined', async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    const ghes: ChromeGhes = {
      permissions: { request: vi.fn(async () => false) },
      scripting: {
        registerContentScripts: vi.fn(async () => {}),
        unregisterContentScripts: vi.fn(async () => {}),
      },
    };
    await initOptions(document, storage, ghes);
    document.querySelector<HTMLInputElement>('#baseUrl')!.value = 'ghe.corp.com';
    document.querySelector<HTMLButtonElement>('#save')!.click();
    await new Promise((r) => setTimeout(r, 0));
    expect(storage.data['baseUrl']).toBe('ghe.corp.com');
    expect(document.querySelector('#status')!.textContent).toBe('Saved (host permission declined)');
  });

  it('reports a failed save instead of staying silent', async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    storage.set = async () => {
      throw new Error('quota exceeded');
    };
    await initOptions(document, storage);
    document.querySelector<HTMLButtonElement>('#save')!.click();
    await new Promise((r) => setTimeout(r, 0));
    expect(document.querySelector('#status')!.textContent).toBe('Save failed');
  });
});
