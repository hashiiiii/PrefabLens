import { describe, expect, it } from "vitest";
import { createChromeAuthRepository } from "../../../src/infrastructure/clients/chrome-auth-client";
import { MemoryStorageArea } from "../../support/memory-storage-area";

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
