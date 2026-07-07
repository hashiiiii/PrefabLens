// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import type { ChromeGhes } from "./ghes";
import { initOptions, OPTIONS_BODY } from "./options";

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

function fakeGhes(granted = true) {
  return {
    permissions: { request: vi.fn(async () => granted) },
    scripting: {
      registerContentScripts: vi.fn(async () => {}),
      unregisterContentScripts: vi.fn(async () => {}),
    },
  } satisfies ChromeGhes;
}

// click ハンドラの async チェーンが status を書き終わるまで待つ(マクロタスクで flush)
const flush = () => new Promise((r) => setTimeout(r, 0));

describe("initOptions", () => {
  it("loads stored values into the form", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    await initOptions(document, fakeStorage({ pat: "tok", baseUrl: "https://ghe.example.com" }));
    expect(document.querySelector<HTMLInputElement>("#pat")?.value).toBe("tok");
    expect(document.querySelector<HTMLInputElement>("#baseUrl")?.value).toBe("https://ghe.example.com");
  });

  it("saves trimmed values and confirms", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(document, storage);
    document.querySelector<HTMLInputElement>("#pat")!.value = "  tok  ";
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    expect(storage.data.pat).toBe("tok");
    expect(document.querySelector("#status")?.textContent).toBe("Saved");
  });

  it("applies ghes registration with the trimmed base url on save", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const ghes = fakeGhes();
    await initOptions(document, fakeStorage(), ghes);
    document.querySelector<HTMLInputElement>("#baseUrl")!.value = "  ghe.corp.com  ";
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    expect(ghes.permissions.request).toHaveBeenCalledWith({ origins: ["https://ghe.corp.com/*"] });
    expect(document.querySelector("#status")?.textContent).toBe("Saved");
  });

  it("saves but reports when the host permission is declined", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(document, storage, fakeGhes(false));
    document.querySelector<HTMLInputElement>("#baseUrl")!.value = "ghe.corp.com";
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    expect(storage.data.baseUrl).toBe("ghe.corp.com");
    expect(document.querySelector("#status")?.textContent).toBe("Saved (host permission declined)");
  });

  it("still saves settings when ghes setup itself fails", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(document, storage, fakeGhes());
    document.querySelector<HTMLInputElement>("#pat")!.value = "tok";
    document.querySelector<HTMLInputElement>("#baseUrl")!.value = "https://"; // originOf が throw する不正 URL
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    expect(storage.data.pat).toBe("tok"); // PAT は捨てない
    expect(document.querySelector("#status")?.textContent).toBe("Saved (GHES setup failed)");
  });

  it("does not touch ghes registration when storage fails", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    storage.set = async () => {
      throw new Error("quota exceeded");
    };
    const ghes = fakeGhes();
    await initOptions(document, storage, ghes);
    document.querySelector<HTMLInputElement>("#baseUrl")!.value = "ghe.corp.com";
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    // 保存に失敗したのに登録だけ進む中途半端な状態を作らない
    expect(ghes.scripting.registerContentScripts).not.toHaveBeenCalled();
    expect(document.querySelector("#status")?.textContent).toBe("Save failed");
  });

  it("reports a failed save instead of staying silent", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    storage.set = async () => {
      throw new Error("quota exceeded");
    };
    await initOptions(document, storage);
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    expect(document.querySelector("#status")?.textContent).toBe("Save failed");
  });
});
