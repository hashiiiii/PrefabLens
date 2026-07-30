import type { TokenStorePort } from "../port/token-store";

export type GetPendingSignInDeps = { tokenStore: TokenStorePort };
export type GetPendingSignIn = () => Promise<{ userCode: string; expiresAt: number } | undefined>;

// Device-page pre-fill: only the code this browser's PR page issued; storage
// failure degrades to no pre-fill (the user pastes the code instead)
export function createGetPendingSignIn(deps: GetPendingSignInDeps): GetPendingSignIn {
  return () => deps.tokenStore.readPendingSignIn().catch(() => undefined);
}
