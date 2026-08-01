import type { AccessToken, PendingSignIn } from "./token";

export type TokenRepository = {
  readAccessToken(): Promise<AccessToken | undefined>;
  saveAccessToken(token: AccessToken): Promise<void>;
  savePendingSignIn(pending: PendingSignIn): Promise<void>;
  readPendingSignIn(): Promise<PendingSignIn | undefined>;
  clearPendingSignIn(): Promise<void>;
};
