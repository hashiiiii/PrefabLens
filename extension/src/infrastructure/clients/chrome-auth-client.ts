import type { AuthRepository } from "../../domain/auth/auth-repository";
import type { PendingSignIn } from "../../domain/auth/pending-sign-in";
import { isAccessToken } from "../../domain/auth/token";
import type { StorageAreaWithRemove } from "../internal/storage-area";

export function createChromeAuthRepository(storage: StorageAreaWithRemove): AuthRepository {
  return {
    loadAccessToken: async () => {
      const stored = await storage.get(["accessToken"]);
      return isAccessToken(stored.accessToken) ? stored.accessToken : undefined;
    },
    saveAccessToken: (token) => storage.set({ accessToken: token }),
    savePendingSignIn: (pending) => storage.set({ signin: pending }),
    loadPendingSignIn: async () => {
      const stored = await storage.get(["signin"]);
      // savePendingSignIn owns the signin key and writes PendingSignIn values.
      return stored.signin as PendingSignIn | undefined;
    },
    clearPendingSignIn: () => storage.remove("signin"),
  };
}
