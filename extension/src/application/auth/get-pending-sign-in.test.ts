import { expect, it } from "vitest";
import type { TokenStorePort } from "../port/token-store";
import { createGetPendingSignIn } from "./get-pending-sign-in";

function tokenStore(readPendingSignIn: TokenStorePort["readPendingSignIn"]): TokenStorePort {
  return {
    readAccessToken: async () => undefined,
    saveAccessToken: async () => {},
    savePendingSignIn: async () => {},
    clearPendingSignIn: async () => {},
    readPendingSignIn,
  };
}

it("returns the stored pending sign-in", async () => {
  const pending = { userCode: "ABCD-1234", expiresAt: 99 };
  const get = createGetPendingSignIn({ tokenStore: tokenStore(async () => pending) });
  expect(await get()).toEqual(pending);
});

it("returns undefined when storage fails (device page then skips pre-fill)", async () => {
  const get = createGetPendingSignIn({
    tokenStore: tokenStore(async () => {
      throw new Error("storage gone");
    }),
  });
  expect(await get()).toBeUndefined();
});
