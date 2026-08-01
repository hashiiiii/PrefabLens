import type { GithubAuthPort } from "../port/github-auth";
import type { TokenStorePort } from "../port/token-store";

// Written before the verification tab opens; /login/device reads it to pre-fill
export type PendingSignIn = { userCode: string; expiresAt: number };

export type SignInState = { inFlight: boolean };

export type SignInUi = {
  showPending(userCode: string, verificationUri: string): void;
  showFailure(message: string): void;
};

export const FAILURE_TEXT = {
  denied: "Authorization denied — try again.",
  expired: "Code expired — try again.",
  failed: "Sign-in failed — try again.",
} as const;

export async function signIn(
  auth: GithubAuthPort,
  tokenStore: TokenStorePort,
  fetchFn: typeof fetch,
  sleep: (ms: number) => Promise<void>,
  openTab: (url: string) => void,
  now: () => number,
  state: SignInState,
  ui: SignInUi,
): Promise<void> {
  if (state.inFlight) return;
  state.inFlight = true;
  try {
    const code = await auth.requestDeviceCode(fetchFn);
    await tokenStore.savePendingSignIn({
      userCode: code.userCode,
      expiresAt: now() + code.expiresIn * 1000,
    });
    ui.showPending(code.userCode, code.verificationUri);
    openTab(code.verificationUri);
    const result = await auth.pollForToken(fetchFn, sleep, code);
    // Success: saveToken → storage.onChanged in index.ts retries auth-blocked panels
    if (result.status === "ok") await tokenStore.saveAccessToken(result.token);
    else ui.showFailure(FAILURE_TEXT[result.status]);
    await tokenStore.clearPendingSignIn();
  } catch {
    ui.showFailure(FAILURE_TEXT.failed);
    await tokenStore.clearPendingSignIn().catch(() => {});
  } finally {
    state.inFlight = false;
  }
}
