import { describe, expect, it } from "vitest";
import type { DeviceCode } from "../../../src/application/gateway/github-auth";
import { err, ok } from "../../../src/domain/result";
import {
  CLIENT_ID,
  createGithubDeviceFlowGateway,
} from "../../../src/infrastructure/clients/github-device-flow-client";

const DEVICE_CODE_URL = "https://github.com/login/device/code";
const TOKEN_URL = "https://github.com/login/oauth/access_token";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const code: DeviceCode = {
  deviceCode: "dc1",
  userCode: "ABCD-1234",
  verificationUri: "https://github.com/login/device",
  interval: 5,
  expiresIn: 900,
};

class VirtualClock {
  now = 0;

  sleep = async (milliseconds: number) => {
    this.now += milliseconds;
  };
}

function expectPost(init: RequestInit | undefined): URLSearchParams {
  expect(init?.method).toBe("POST");
  expect(new Headers(init?.headers).get("accept")).toBe("application/json");
  expect(init?.credentials).toBe("omit");
  return new URLSearchParams(String(init?.body));
}

describe("createGithubDeviceFlowGateway", () => {
  it("maps a successful device-code response", async () => {
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== DEVICE_CODE_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      const form = expectPost(init);
      expect(form.get("client_id")).toBe(CLIENT_ID);
      expect(form.get("scope")).toBe("repo");
      return json({
        device_code: "dc1",
        user_code: "ABCD-1234",
        verification_uri: "https://github.com/login/device",
        interval: 5,
        expires_in: 900,
      });
    }) as typeof fetch;

    const auth = createGithubDeviceFlowGateway(route);

    await expect(auth.requestDeviceCode()).resolves.toEqual(ok(code));
  });

  it("returns a failure for a device-code HTTP error", async () => {
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== DEVICE_CODE_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      return json({}, 500);
    }) as typeof fetch;

    await expect(createGithubDeviceFlowGateway(route).requestDeviceCode()).resolves.toEqual(
      err({ kind: "device-flow-failed", message: "device code request failed (HTTP 500)" }),
    );
  });

  it("returns the device-code error description", async () => {
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== DEVICE_CODE_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      return json({ error: "invalid_client", error_description: "bad client id" });
    }) as typeof fetch;

    await expect(createGithubDeviceFlowGateway(route).requestDeviceCode()).resolves.toEqual(
      err({ kind: "device-flow-failed", message: "bad client id" }),
    );
  });

  it("returns the token from the first poll", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== TOKEN_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      expect(clock.now).toBe(5_000);
      const form = expectPost(init);
      expect(form.get("client_id")).toBe(CLIENT_ID);
      expect(form.get("device_code")).toBe("dc1");
      expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:device_code");
      return json({ access_token: "tok123" });
    }) as typeof fetch;

    const result = await createGithubDeviceFlowGateway(route, clock.sleep).pollForToken(code);

    expect(result).toEqual({ status: "ok", token: "tok123" });
    expect(clock.now).toBe(5_000);
  });

  it("repeats with the same interval after authorization_pending", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== TOKEN_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      if (clock.now === 5_000 || clock.now === 10_000) return json({ error: "authorization_pending" });
      if (clock.now === 15_000) return json({ access_token: "tok123" });
      throw new Error(`Unexpected poll time: ${clock.now}`);
    }) as typeof fetch;

    const result = await createGithubDeviceFlowGateway(route, clock.sleep).pollForToken(code);

    expect(result).toEqual({ status: "ok", token: "tok123" });
    expect(clock.now).toBe(15_000);
  });

  it("uses the response interval after slow_down", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== TOKEN_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      if (clock.now === 5_000) return json({ error: "slow_down", interval: 8 });
      if (clock.now === 13_000) return json({ access_token: "tok123" });
      throw new Error(`Unexpected poll time: ${clock.now}`);
    }) as typeof fetch;

    await expect(createGithubDeviceFlowGateway(route, clock.sleep).pollForToken(code)).resolves.toEqual({
      status: "ok",
      token: "tok123",
    });
    expect(clock.now).toBe(13_000);
  });

  it("adds five seconds when slow_down has no interval", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== TOKEN_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      if (clock.now === 5_000) return json({ error: "slow_down" });
      if (clock.now === 15_000) return json({ access_token: "tok123" });
      throw new Error(`Unexpected poll time: ${clock.now}`);
    }) as typeof fetch;

    await expect(createGithubDeviceFlowGateway(route, clock.sleep).pollForToken(code)).resolves.toEqual({
      status: "ok",
      token: "tok123",
    });
    expect(clock.now).toBe(15_000);
  });

  it.each([
    [{ error: "expired_token" }, 200, { status: "expired" }],
    [{ error: "access_denied" }, 200, { status: "denied" }],
    [{ error: "incorrect_client_credentials" }, 200, { status: "failed" }],
    [{}, 500, { status: "failed" }],
  ] as const)("maps a terminal token response", async (body, status, expected) => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== TOKEN_URL) throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      expect(clock.now).toBe(5_000);
      return json(body, status);
    }) as typeof fetch;

    await expect(createGithubDeviceFlowGateway(route, clock.sleep).pollForToken(code)).resolves.toEqual(expected);
  });
});
