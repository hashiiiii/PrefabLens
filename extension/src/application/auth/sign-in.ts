import type { TokenRepository } from "../../domain/auth/token-repository";
import type { GithubAuthGateway } from "../gateway/github-auth";

const FAILURE_TEXT = {
  denied: "Authorization denied — try again.",
  expired: "Code expired — try again.",
  failed: "Sign-in failed — try again.",
} as const;

export async function signIn(
  auth: GithubAuthGateway,
  tokenStore: TokenRepository,
  fetchFn: typeof fetch,
  sleep: (ms: number) => Promise<void>,
  openTab: (url: string) => void,
  now: () => number,
  state: { inFlight: boolean },
  ui: {
    showPending(userCode: string, verificationUri: string): void;
    showFailure(message: string): void;
  },
): Promise<void> {
  if (state.inFlight) return;
  state.inFlight = true;
  try {
    const code = await auth.requestDeviceCode(fetchFn);
    if (!code.ok) {
      ui.showFailure(FAILURE_TEXT.failed);
      return;
    }
    // Save the pending sign-in before the verification tab opens. /login/device reads it to pre-fill the code.
    await tokenStore.savePendingSignIn({
      userCode: code.value.userCode,
      expiresAt: now() + code.value.expiresIn * 1000,
    });
    ui.showPending(code.value.userCode, code.value.verificationUri);
    openTab(code.value.verificationUri);
    const result = await auth.pollForToken(fetchFn, sleep, code.value);
    // Success: saveToken → storage.onChanged in index.ts retries auth-blocked panels
    if (result.status === "ok") await tokenStore.saveAccessToken(result.token);
    else ui.showFailure(FAILURE_TEXT[result.status]);
    await tokenStore.clearPendingSignIn();
  } catch {
    // Only unexpected rejections (storage) land here. Expected failures arrive as values above.
    ui.showFailure(FAILURE_TEXT.failed);
    await tokenStore.clearPendingSignIn().catch(() => {});
  } finally {
    state.inFlight = false;
  }
}
