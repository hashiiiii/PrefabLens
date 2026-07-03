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
