import { describe, expect, it } from "vitest";
import { createChromeAuthRepository } from "../../../src/infrastructure/clients/chrome-auth-client";
import type { StorageAreaWithRemove } from "../../../src/infrastructure/internal/storage-area";

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

describe("createChromeAuthRepository", () => {
  it("round-trips the access token", async () => {
    const auth = createChromeAuthRepository(new MemoryStorageArea());

    expect(await auth.loadAccessToken()).toBeUndefined();
    await auth.saveAccessToken("tok");
    expect(await auth.loadAccessToken()).toBe("tok");
  });

  it("round-trips pending sign-in data", async () => {
    const auth = createChromeAuthRepository(new MemoryStorageArea());

    expect(await auth.loadPendingSignIn()).toBeUndefined();
    await auth.savePendingSignIn({ userCode: "ABCD-1234", expiresAt: 99 });
    expect(await auth.loadPendingSignIn()).toEqual({ userCode: "ABCD-1234", expiresAt: 99 });
    await auth.clearPendingSignIn();
    expect(await auth.loadPendingSignIn()).toBeUndefined();
  });
});
