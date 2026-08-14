import type { AuthRepository } from "../../domain/auth/auth-repository";
import type { GithubAuthGateway, PollResult } from "../gateway/github-auth";

// Application reports only the outcome kind. Presentation owns the user-visible text.
export type SignInFailure = Exclude<PollResult["status"], "ok">;

export type SignInEvent =
  | { status: "pending"; userCode: string; verificationUri: string }
  | { status: "ok" }
  | { status: "failed"; reason: SignInFailure };

export async function* signIn(
  githubAuthGateway: GithubAuthGateway,
  authRepository: AuthRepository,
  now: () => number,
  state: { inFlight: boolean },
): AsyncGenerator<SignInEvent> {
  if (state.inFlight) return;
  state.inFlight = true;
  try {
    const code = await githubAuthGateway.requestDeviceCode();
    if (!code.ok) {
      yield { status: "failed", reason: "failed" };
      return;
    }
    // /login/device reads storage before presentation opens it, so pending state must exist before the event.
    await authRepository.savePendingSignIn({
      userCode: code.value.userCode,
      expiresAt: now() + code.value.expiresIn * 1000,
    });
    yield {
      status: "pending",
      userCode: code.value.userCode,
      verificationUri: code.value.verificationUri,
    };
    const result = await githubAuthGateway.pollForToken(code.value);
    // storage.onChanged retries auth-blocked panels after the token is saved.
    if (result.status === "ok") {
      await authRepository.saveAccessToken(result.token);
      await authRepository.clearPendingSignIn();
      yield { status: "ok" };
      return;
    }
    await authRepository.clearPendingSignIn();
    yield { status: "failed", reason: result.status };
  } catch {
    // Unexpected gateway, parsing, or storage rejections land here. Expected failures arrive as values above.
    await authRepository.clearPendingSignIn().catch(() => {});
    yield { status: "failed", reason: "failed" };
  } finally {
    state.inFlight = false;
  }
}
