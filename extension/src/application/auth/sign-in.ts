import type { TokenRepository } from "../../domain/auth/token-repository";
import type { GithubAuthGateway, PollResult } from "../gateway/github-auth";

// Application reports only the outcome kind. Presentation owns the user-visible text.
export type SignInFailure = Exclude<PollResult["status"], "ok">;

export type SignInEvent =
  | { status: "pending"; userCode: string; verificationUri: string }
  | { status: "ok" }
  | { status: "failed"; reason: SignInFailure };

export async function* signIn(
  auth: GithubAuthGateway,
  tokenStore: TokenRepository,
  fetchFn: typeof fetch,
  sleep: (ms: number) => Promise<void>,
  now: () => number,
  state: { inFlight: boolean },
): AsyncGenerator<SignInEvent> {
  if (state.inFlight) return;
  state.inFlight = true;
  try {
    const code = await auth.requestDeviceCode(fetchFn);
    if (!code.ok) {
      yield { status: "failed", reason: "failed" };
      return;
    }
    // Save the pending sign-in before yielding. Presentation opens the tab after pending.
    // /login/device reads storage to pre-fill the code.
    await tokenStore.savePendingSignIn({
      userCode: code.value.userCode,
      expiresAt: now() + code.value.expiresIn * 1000,
    });
    yield {
      status: "pending",
      userCode: code.value.userCode,
      verificationUri: code.value.verificationUri,
    };
    const result = await auth.pollForToken(fetchFn, sleep, code.value);
    // Success: saveToken fires storage.onChanged, and index.ts retries auth-blocked panels
    if (result.status === "ok") {
      await tokenStore.saveAccessToken(result.token);
      await tokenStore.clearPendingSignIn();
      yield { status: "ok" };
      return;
    }
    await tokenStore.clearPendingSignIn();
    yield { status: "failed", reason: result.status };
  } catch {
    // Only unexpected rejections (storage) land here. Expected failures arrive as values above.
    await tokenStore.clearPendingSignIn().catch(() => {});
    yield { status: "failed", reason: "failed" };
  } finally {
    state.inFlight = false;
  }
}
