// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
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

// Wait until the click handler's async chain finishes writing status (flush via a macrotask)
const flush = () => new Promise((r) => setTimeout(r, 0));

describe("initOptions", () => {
  it("loads the stored pat into the form", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    await initOptions(document, fakeStorage({ pat: "tok" }));
    expect(document.querySelector<HTMLInputElement>("#pat")?.value).toBe("tok");
  });

  it("saves the trimmed pat and confirms", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(document, storage);
    document.querySelector<HTMLInputElement>("#pat")!.value = "  tok  ";
    document.querySelector<HTMLButtonElement>("#save")?.click();
    await flush();
    expect(storage.data.pat).toBe("tok");
    expect(document.querySelector("#status")?.textContent).toBe("Saved");
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
