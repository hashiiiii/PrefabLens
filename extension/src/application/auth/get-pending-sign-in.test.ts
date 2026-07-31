import { expect, it } from "vitest";
import type { TokenStorePort } from "../port/token-store";
import { getPendingSignIn } from "./get-pending-sign-in";

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
  expect(await getPendingSignIn(tokenStore(async () => pending))).toEqual(pending);
});

it("returns undefined when storage fails (device page then skips pre-fill)", async () => {
  const store = tokenStore(async () => {
    throw new Error("storage gone");
  });
  expect(await getPendingSignIn(store)).toBeUndefined();
});
