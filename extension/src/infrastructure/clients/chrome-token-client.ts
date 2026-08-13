import type { PendingSignIn } from "../../domain/auth/token";
import type { TokenRepository } from "../../domain/auth/token-repository";
import type { StorageAreaWithRemove } from "../internal/storage-area";

export function createChromeTokenRepository(storage: StorageAreaWithRemove): TokenRepository {
  return {
    readAccessToken: async () => {
      const stored = await storage.get(["accessToken"]);
      return typeof stored.accessToken === "string" ? stored.accessToken : undefined;
    },
    saveAccessToken: (token) => storage.set({ accessToken: token }),
    savePendingSignIn: (pending) => storage.set({ signin: pending }),
    readPendingSignIn: async () => {
      const stored = await storage.get(["signin"]);
      return stored.signin as PendingSignIn | undefined;
    },
    clearPendingSignIn: () => storage.remove("signin"),
  };
}
