// Public client id of the GitHub OAuth App (device flow enabled).
export const CLIENT_ID = "Ov23liYYM6t34p7Hxkc1";

export type DeviceCode = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  interval: number;
  expiresIn: number;
};

export type PollResult = { status: "ok"; token: string } | { status: "denied" } | { status: "expired" };

type DeviceCodeResponse =
  | { device_code: string; user_code: string; verification_uri: string; interval: number; expires_in: number }
  | { error: string; error_description?: string };

type TokenResponse = { access_token: string } | { error: string; interval?: number };

export async function requestDeviceCode(fetchFn: typeof fetch): Promise<DeviceCode> {
  const res = await fetchFn("https://github.com/login/device/code", {
    method: "POST",
    headers: { accept: "application/json" },
    body: new URLSearchParams({ client_id: CLIENT_ID, scope: "repo" }),
  });
  if (!res.ok) throw new Error(`device code request failed (HTTP ${res.status})`);
  const body = (await res.json()) as DeviceCodeResponse;
  if ("error" in body) throw new Error(body.error_description ?? body.error);
  return {
    deviceCode: body.device_code,
    userCode: body.user_code,
    verificationUri: body.verification_uri,
    interval: body.interval,
    expiresIn: body.expires_in,
  };
}

export async function pollForToken(
  fetchFn: typeof fetch,
  sleep: (ms: number) => Promise<void>,
  code: DeviceCode,
): Promise<PollResult> {
  let interval = code.interval;
  for (;;) {
    await sleep(interval * 1000);
    const res = await fetchFn("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { accept: "application/json" },
      body: new URLSearchParams({
        client_id: CLIENT_ID,
        device_code: code.deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      }),
    });
    if (!res.ok) throw new Error(`device token poll failed (HTTP ${res.status})`);
    const body = (await res.json()) as TokenResponse;
    if ("access_token" in body) return { status: "ok", token: body.access_token };
    switch (body.error) {
      case "authorization_pending":
        continue;
      case "slow_down":
        // GitHub's own interval already accounts for the requested backoff; fall back to +5s otherwise.
        interval = body.interval ?? interval + 5;
        continue;
      case "expired_token":
        return { status: "expired" };
      case "access_denied":
        return { status: "denied" };
      default:
        throw new Error(body.error ?? "device token poll failed: unexpected response");
    }
  }
}
