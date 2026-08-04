import { describe, expect, it } from "vitest";
import { createChromeTokenRepository, readAccessToken, type SettingsStorage } from "./chrome-token-repository";

function mem(initial: Record<string, unknown> = {}): SettingsStorage & { data: Record<string, unknown> } {
  const data = { ...initial };
  // The token repository reads only by key array. The fake normalizes anyway to satisfy StorageArea.
  const asArray = (keys: string | string[] | null): string[] =>
    keys === null ? Object.keys(data) : Array.isArray(keys) ? keys : [keys];
  return {
    data,
    get: async (keys) =>
      Object.fromEntries(
        asArray(keys)
          .filter((k) => k in data)
          .map((k) => [k, data[k]]),
      ),
    set: async (items) => void Object.assign(data, items),
    remove: async (keys) => {
      for (const k of asArray(keys)) delete data[k];
    },
  };
}

describe("readAccessToken", () => {
  it("returns accessToken when present", async () => {
    expect(await readAccessToken(mem({ accessToken: "tok" }))).toBe("tok");
  });

  it("returns undefined when neither key exists", async () => {
    expect(await readAccessToken(mem())).toBeUndefined();
  });

  it("migrates legacy pat to accessToken and removes pat", async () => {
    const s = mem({ pat: "legacy" });
    expect(await readAccessToken(s)).toBe("legacy");
    expect(s.data.accessToken).toBe("legacy");
    expect(s.data.pat).toBeUndefined();
  });

  it("prefers accessToken over pat without rewriting", async () => {
    const s = mem({ accessToken: "new", pat: "old" });
    expect(await readAccessToken(s)).toBe("new");
    expect(s.data.pat).toBe("old");
  });
});

it("round-trips the pending sign-in", async () => {
  const store = createChromeTokenRepository(mem());
  expect(await store.readPendingSignIn()).toBeUndefined();
  await store.savePendingSignIn({ userCode: "ABCD-1234", expiresAt: 99 });
  expect(await store.readPendingSignIn()).toEqual({ userCode: "ABCD-1234", expiresAt: 99 });
  await store.clearPendingSignIn();
  expect(await store.readPendingSignIn()).toBeUndefined();
});
