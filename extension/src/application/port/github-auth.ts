export type DeviceCode = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  interval: number;
  expiresIn: number;
};

export type PollResult = { status: "ok"; token: string } | { status: "denied" } | { status: "expired" };

export type GithubAuthPort = {
  requestDeviceCode(fetchFn: typeof fetch): Promise<DeviceCode>;
  pollForToken(fetchFn: typeof fetch, sleep: (ms: number) => Promise<void>, code: DeviceCode): Promise<PollResult>;
};
