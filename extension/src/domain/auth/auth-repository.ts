import type { PendingSignIn } from "./pending-sign-in";
import type { AccessToken } from "./token";

export type AuthRepository = {
  loadAccessToken(): Promise<AccessToken | undefined>;
  saveAccessToken(token: AccessToken): Promise<void>;
  savePendingSignIn(pending: PendingSignIn): Promise<void>;
  loadPendingSignIn(): Promise<PendingSignIn | undefined>;
  clearPendingSignIn(): Promise<void>;
};
