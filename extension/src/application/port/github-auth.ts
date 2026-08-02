import type { Result } from "../../domain/result";

export type DeviceCode = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  interval: number;
  expiresIn: number;
};

export type DeviceFlowFailure = { kind: "device-flow-failed"; message: string };

// "failed" covers HTTP errors and unexpected poll responses: expected outcomes, not throws
export type PollResult =
  | { status: "ok"; token: string }
  | { status: "denied" }
  | { status: "expired" }
  | { status: "failed" };

export type GithubAuthPort = {
  requestDeviceCode(fetchFn: typeof fetch): Promise<Result<DeviceCode, DeviceFlowFailure>>;
  pollForToken(fetchFn: typeof fetch, sleep: (ms: number) => Promise<void>, code: DeviceCode): Promise<PollResult>;
};
