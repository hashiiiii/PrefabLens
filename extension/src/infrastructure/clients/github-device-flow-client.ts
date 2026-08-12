import type {
  DeviceCode,
  DeviceFlowFailure,
  GithubAuthGateway,
  PollResult,
} from "../../application/gateway/github-auth";
import { err, ok, type Result } from "../../domain/result";

export const CLIENT_ID = "Ov23liYYM6t34p7Hxkc1";

type DeviceCodeResponse =
  | { device_code: string; user_code: string; verification_uri: string; interval: number; expires_in: number }
  | { error: string; error_description?: string };

type TokenResponse = { access_token: string } | { error: string; interval?: number };

const failed = (message: string) => err<DeviceFlowFailure>({ kind: "device-flow-failed", message });

async function requestDeviceCode(fetchFn: typeof fetch): Promise<Result<DeviceCode, DeviceFlowFailure>> {
  const res = await fetchFn(`${__GITHUB_ORIGIN__}/login/device/code`, {
    method: "POST",
    headers: { accept: "application/json" },
    body: new URLSearchParams({ client_id: CLIENT_ID, scope: "repo" }),
    // Cookie-less: same-origin content-script call must not attach session state
    credentials: "omit",
  });
  if (!res.ok) return failed(`device code request failed (HTTP ${res.status})`);
  const body = (await res.json()) as DeviceCodeResponse;
  if ("error" in body) return failed(body.error_description ?? body.error);
  return ok({
    deviceCode: body.device_code,
    userCode: body.user_code,
    verificationUri: body.verification_uri,
    interval: body.interval,
    expiresIn: body.expires_in,
  });
}

async function pollForToken(
  fetchFn: typeof fetch,
  sleep: (ms: number) => Promise<void>,
  code: DeviceCode,
): Promise<PollResult> {
  let interval = code.interval;
  for (;;) {
    await sleep(interval * 1000);
    const res = await fetchFn(`${__GITHUB_ORIGIN__}/login/oauth/access_token`, {
      method: "POST",
      headers: { accept: "application/json" },
      body: new URLSearchParams({
        client_id: CLIENT_ID,
        device_code: code.deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      }),
      credentials: "omit",
    });
    if (!res.ok) return { status: "failed" };
    const body = (await res.json()) as TokenResponse;
    if ("access_token" in body) return { status: "ok", token: body.access_token };
    switch (body.error) {
      case "authorization_pending":
        continue;
      case "slow_down":
        interval = body.interval ?? interval + 5;
        continue;
      case "expired_token":
        return { status: "expired" };
      case "access_denied":
        return { status: "denied" };
      default:
        return { status: "failed" };
    }
  }
}

const defaultFetch: typeof fetch = (input, init) => fetch(input, init);
const defaultSleep = (milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

export function createGithubDeviceFlowClient(
  fetchFn: typeof fetch = defaultFetch,
  sleep: (ms: number) => Promise<void> = defaultSleep,
): GithubAuthGateway {
  return {
    requestDeviceCode: () => requestDeviceCode(fetchFn),
    pollForToken: (code) => pollForToken(fetchFn, sleep, code),
  };
}
