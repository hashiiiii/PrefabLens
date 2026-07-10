import type { DeviceCode, PollResult } from "../github/deviceFlow";

// Written to storage.local before the verification tab opens; the /login/device
// content script reads it to pre-fill the code.
export type PendingSignIn = { userCode: string; expiresAt: number };

export type SignInIo = {
  requestDeviceCode(): Promise<DeviceCode>;
  pollForToken(code: DeviceCode): Promise<PollResult>;
  savePending(pending: PendingSignIn): Promise<void>;
  clearPending(): Promise<void>;
  saveToken(token: string): Promise<void>;
  openTab(url: string): void;
  now(): number;
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

export function createSignIn(io: SignInIo): (ui: SignInUi) => Promise<void> {
  let inFlight = false; // one flow per page: a second click while polling is a no-op
  return async (ui) => {
    if (inFlight) return;
    inFlight = true;
    try {
      const code = await io.requestDeviceCode();
      await io.savePending({ userCode: code.userCode, expiresAt: io.now() + code.expiresIn * 1000 });
      ui.showPending(code.userCode, code.verificationUri);
      io.openTab(code.verificationUri);
      const result = await io.pollForToken(code);
      // Success needs no ui call: saveToken writes `pat`, and the storage.onChanged
      // retry in content/index.ts repaints every auth-blocked panel, including this one.
      if (result.status === "ok") await io.saveToken(result.token);
      else ui.showFailure(FAILURE_TEXT[result.status]);
      await io.clearPending();
    } catch {
      ui.showFailure(FAILURE_TEXT.failed);
      await io.clearPending().catch(() => {});
    } finally {
      inFlight = false;
    }
  };
}
