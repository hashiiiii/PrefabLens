import type { PendingSignIn } from "../../domain/auth/token";
import type { TokenRepository } from "../../domain/auth/token-repository";
import type { StorageAreaWithRemove } from "./storage-area";

export type SettingsStorage = StorageAreaWithRemove;

// Prefer accessToken. A one-shot move of the legacy pat serves existing installs.
export async function readAccessToken(storage: SettingsStorage): Promise<string | undefined> {
  const stored = await storage.get(["accessToken", "pat"]);
  if (typeof stored.accessToken === "string") return stored.accessToken;
  if (typeof stored.pat !== "string") return undefined;
  await storage.set({ accessToken: stored.pat });
  await storage.remove("pat");
  return stored.pat;
}

export function createChromeTokenRepository(storage: SettingsStorage): TokenRepository {
  return {
    readAccessToken: () => readAccessToken(storage),
    saveAccessToken: (token) => storage.set({ accessToken: token }),
    savePendingSignIn: (pending) => storage.set({ signin: pending }),
    readPendingSignIn: async () => {
      const stored = await storage.get(["signin"]);
      return stored.signin as PendingSignIn | undefined;
    },
    clearPendingSignIn: () => storage.remove("signin"),
  };
}
