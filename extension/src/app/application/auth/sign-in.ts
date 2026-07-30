import type { GithubAuthPort } from "../port/github-auth";
import type { TokenStorePort } from "../port/token-store";

// Written before the verification tab opens; /login/device reads it to pre-fill
export type PendingSignIn = { userCode: string; expiresAt: number };

export type SignInDeps = {
  auth: GithubAuthPort;
  tokenStore: TokenStorePort;
  fetchFn: typeof fetch;
  sleep: (ms: number) => Promise<void>;
  openTab: (url: string) => void;
  now: () => number;
};

export type SignInUi = {
  showPending(userCode: string, verificationUri: string): void;
  showFailure(message: string): void;
};

export const FAILURE_TEXT = {
  denied: "Authorization denied — try again.",
  expired: "Code expired — try again.",
  failed: "Sign-in failed — try again.",
} as const;

export function createSignIn(deps: SignInDeps): (ui: SignInUi) => Promise<void> {
  let inFlight = false; // one flow per page; second click while polling is a no-op
  return async (ui) => {
    if (inFlight) return;
    inFlight = true;
    try {
      const code = await deps.auth.requestDeviceCode(deps.fetchFn);
      await deps.tokenStore.savePendingSignIn({
        userCode: code.userCode,
        expiresAt: deps.now() + code.expiresIn * 1000,
      });
      ui.showPending(code.userCode, code.verificationUri);
      deps.openTab(code.verificationUri);
      const result = await deps.auth.pollForToken(deps.fetchFn, deps.sleep, code);
      // Success: saveToken → storage.onChanged in index.ts retries auth-blocked panels
      if (result.status === "ok") await deps.tokenStore.saveAccessToken(result.token);
      else ui.showFailure(FAILURE_TEXT[result.status]);
      await deps.tokenStore.clearPendingSignIn();
    } catch {
      ui.showFailure(FAILURE_TEXT.failed);
      await deps.tokenStore.clearPendingSignIn().catch(() => {});
    } finally {
      inFlight = false;
    }
  };
}
