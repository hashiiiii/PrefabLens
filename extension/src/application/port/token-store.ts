export type TokenStorePort = {
  readAccessToken(): Promise<string | undefined>;
  saveAccessToken(token: string): Promise<void>;
  savePendingSignIn(pending: { userCode: string; expiresAt: number }): Promise<void>;
  readPendingSignIn(): Promise<{ userCode: string; expiresAt: number } | undefined>;
  clearPendingSignIn(): Promise<void>;
};
