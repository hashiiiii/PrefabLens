import type { AuthRepository } from "../../domain/auth/auth-repository";
import type { PendingSignIn } from "../../domain/auth/pending-sign-in";
import type { StorageAreaWithRemove } from "../internal/storage-area";

export function createChromeAuthRepository(storage: StorageAreaWithRemove): AuthRepository {
  return {
    loadAccessToken: async () => {
      const stored = await storage.get(["accessToken"]);
      return typeof stored.accessToken === "string" ? stored.accessToken : undefined;
    },
    saveAccessToken: (token) => storage.set({ accessToken: token }),
    savePendingSignIn: (pending) => storage.set({ signin: pending }),
    loadPendingSignIn: async () => {
      const stored = await storage.get(["signin"]);
      return stored.signin as PendingSignIn | undefined;
    },
    clearPendingSignIn: () => storage.remove("signin"),
  };
}
