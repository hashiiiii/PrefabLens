import type { Result } from "../../domain/result";

export type DeviceCode = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  interval: number;
  expiresIn: number;
};

export type DeviceFlowFailure = { kind: "device-flow-failed"; message: string };

// "failed" covers HTTP errors and unexpected poll responses: expected outcomes, not thrown errors
export type PollResult =
  | { status: "ok"; token: string }
  | { status: "denied" }
  | { status: "expired" }
  | { status: "failed" };

export type GithubAuthGateway = {
  requestDeviceCode(): Promise<Result<DeviceCode, DeviceFlowFailure>>;
  pollForToken(code: DeviceCode): Promise<PollResult>;
};
