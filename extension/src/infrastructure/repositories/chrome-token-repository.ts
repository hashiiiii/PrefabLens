import type { PendingSignIn } from "../../domain/auth/token";
import type { TokenRepository } from "../../domain/auth/token-repository";

export type SettingsStorage = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
  remove(keys: string | string[]): Promise<void>;
};

// Prefer accessToken; one-shot move of legacy pat for existing installs.
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
