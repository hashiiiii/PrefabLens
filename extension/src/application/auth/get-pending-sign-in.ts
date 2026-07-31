import type { TokenStorePort } from "../port/token-store";

// Device-page pre-fill: only the code this browser's PR page issued; storage
// failure degrades to no pre-fill (the user pastes the code instead)
export function getPendingSignIn(
  tokenStore: TokenStorePort,
): Promise<{ userCode: string; expiresAt: number } | undefined> {
  return tokenStore.readPendingSignIn().catch(() => undefined);
}
