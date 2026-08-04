import { describe, expect, it } from "vitest";
import type { DeviceCode } from "../../application/gateway/github-auth";
import { err, ok } from "../../domain/result";
import { must } from "../../internal/must";
import { CLIENT_ID, pollForToken, requestDeviceCode } from "./github-device-flow-client";

// Queue-based fetch fake: each call shifts the next canned Response and records the request.
function fakeFetch(responses: Response[]) {
  const queue = [...responses];
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    const next = queue.shift();
    if (!next) throw new Error("fake fetch queue exhausted");
    return next;
  }) as typeof fetch;
  return { fn, calls };
}

// Fake sleep: records the requested delay and resolves immediately, so polling tests run instantly.
function fakeSleep() {
  const delays: number[] = [];
  const fn = async (ms: number) => {
    delays.push(ms);
  };
  return { fn, delays };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const code: DeviceCode = {
  deviceCode: "dc1",
  userCode: "ABCD-1234",
  verificationUri: "https://github.com/login/device",
  interval: 5,
  expiresIn: 900,
};

describe("requestDeviceCode", () => {
  it("posts client_id and scope, mapping the snake_case response to camelCase", async () => {
    const { fn, calls } = fakeFetch([
      json({
        device_code: "dc1",
        user_code: "ABCD-1234",
        verification_uri: "https://github.com/login/device",
        interval: 5,
        expires_in: 900,
      }),
    ]);
    const result = await requestDeviceCode(fn);
    expect(result).toEqual(ok(code));
    expect(calls[0]?.url).toBe("https://github.com/login/device/code");
    expect(calls[0]?.init.method).toBe("POST");
    expect((must(calls[0]).init.headers as Record<string, string>).accept).toBe("application/json");
    expect(String(calls[0]?.init.body)).toBe(`client_id=${CLIENT_ID}&scope=repo`);
    // Cookie-less like a CLI: the content-script call is same-origin on github.com and must not carry session state.
    expect(calls[0]?.init.credentials).toBe("omit");
  });

  it("returns a device-flow failure on a non-OK response", async () => {
    // An HTTP failure is an expected outcome: it travels as a Result, not a thrown error
    const { fn } = fakeFetch([json({}, 500)]);
    await expect(requestDeviceCode(fn)).resolves.toEqual(
      err({ kind: "device-flow-failed", message: "device code request failed (HTTP 500)" }),
    );
  });

  it("returns a device-flow failure when the JSON body carries an error field", async () => {
    const { fn } = fakeFetch([json({ error: "invalid_client", error_description: "bad client id" })]);
    await expect(requestDeviceCode(fn)).resolves.toEqual(err({ kind: "device-flow-failed", message: "bad client id" }));
  });
});

describe("pollForToken", () => {
  it("returns the token on the first poll, sleeping once for the initial interval", async () => {
    const { fn, calls } = fakeFetch([json({ access_token: "tok123" })]);
    const { fn: sleep, delays } = fakeSleep();
    const result = await pollForToken(fn, sleep, code);
    expect(result).toEqual({ status: "ok", token: "tok123" });
    expect(delays).toEqual([5000]); // sleep(interval * 1000) runs before every poll, including the first
    expect(calls[0]?.url).toBe("https://github.com/login/oauth/access_token");
    expect((must(calls[0]).init.headers as Record<string, string>).accept).toBe("application/json");
    expect(String(calls[0]?.init.body)).toBe(
      `client_id=${CLIENT_ID}&device_code=dc1&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code`,
    );
    expect(calls[0]?.init.credentials).toBe("omit");
  });

  it("keeps polling through authorization_pending until the token arrives", async () => {
    const { fn } = fakeFetch([
      json({ error: "authorization_pending" }),
      json({ error: "authorization_pending" }),
      json({ access_token: "tok123" }),
    ]);
    const { fn: sleep, delays } = fakeSleep();
    const result = await pollForToken(fn, sleep, code);
    expect(result).toEqual({ status: "ok", token: "tok123" });
    expect(delays).toEqual([5000, 5000, 5000]); // interval is unchanged while pending
  });

  it("slow_down without an interval field adds 5s to the current interval", async () => {
    const { fn } = fakeFetch([json({ error: "slow_down" }), json({ access_token: "tok123" })]);
    const { fn: sleep, delays } = fakeSleep();
    await pollForToken(fn, sleep, code);
    expect(delays).toEqual([5000, 10000]); // 5 (initial) + 5 (slow_down bump)
  });

  it("slow_down with an interval field uses it as-is instead of adding 5s", async () => {
    const { fn } = fakeFetch([json({ error: "slow_down", interval: 8 }), json({ access_token: "tok123" })]);
    const { fn: sleep, delays } = fakeSleep();
    await pollForToken(fn, sleep, code);
    // An unconditional +5 fallback gives 10000 (5+5). The 8000 proves that the
    // response's own interval wins when the server supplies one.
    expect(delays).toEqual([5000, 8000]);
  });

  it("maps expired_token to an expired status", async () => {
    const { fn } = fakeFetch([json({ error: "expired_token" })]);
    const result = await pollForToken(fn, fakeSleep().fn, code);
    expect(result).toEqual({ status: "expired" });
  });

  it("maps access_denied to a denied status", async () => {
    const { fn } = fakeFetch([json({ error: "access_denied" })]);
    const result = await pollForToken(fn, fakeSleep().fn, code);
    expect(result).toEqual({ status: "denied" });
  });

  it("maps an unrecognized error code to a failed status", async () => {
    const { fn } = fakeFetch([json({ error: "incorrect_client_credentials" })]);
    await expect(pollForToken(fn, fakeSleep().fn, code)).resolves.toEqual({ status: "failed" });
  });

  it("maps a non-OK response to a failed status", async () => {
    const { fn } = fakeFetch([json({}, 500)]);
    await expect(pollForToken(fn, fakeSleep().fn, code)).resolves.toEqual({ status: "failed" });
  });
});
