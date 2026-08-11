import { describe, expect, it } from "vitest";
import type { StorageAreaWithRemove } from "../internal/storage-area";
import { createChromeTokenClient } from "./chrome-token-client";

class MemoryStorageArea implements StorageAreaWithRemove {
  private readonly values: Record<string, unknown>;

  constructor(initial: Record<string, unknown> = {}) {
    this.values = { ...initial };
  }

  async get(keys: string | string[] | null): Promise<Record<string, unknown>> {
    const selected = keys === null ? Object.keys(this.values) : Array.isArray(keys) ? keys : [keys];
    return Object.fromEntries(selected.filter((key) => key in this.values).map((key) => [key, this.values[key]]));
  }

  async set(items: Record<string, unknown>): Promise<void> {
    Object.assign(this.values, items);
  }

  async remove(keys: string | string[]): Promise<void> {
    for (const key of Array.isArray(keys) ? keys : [keys]) delete this.values[key];
  }
}

describe("createChromeTokenClient", () => {
  it("reads the stored access token", async () => {
    const tokens = createChromeTokenClient(new MemoryStorageArea({ accessToken: "tok" }));

    expect(await tokens.readAccessToken()).toBe("tok");
  });

  it("returns undefined when the access token is absent", async () => {
    const tokens = createChromeTokenClient(new MemoryStorageArea());

    expect(await tokens.readAccessToken()).toBeUndefined();
  });

  it("stores the access token", async () => {
    const tokens = createChromeTokenClient(new MemoryStorageArea());

    await tokens.saveAccessToken("tok");

    expect(await tokens.readAccessToken()).toBe("tok");
  });

  it("round-trips pending sign-in data", async () => {
    const tokens = createChromeTokenClient(new MemoryStorageArea());

    expect(await tokens.readPendingSignIn()).toBeUndefined();
    await tokens.savePendingSignIn({ userCode: "ABCD-1234", expiresAt: 99 });
    expect(await tokens.readPendingSignIn()).toEqual({ userCode: "ABCD-1234", expiresAt: 99 });
    await tokens.clearPendingSignIn();
    expect(await tokens.readPendingSignIn()).toBeUndefined();
  });
});
