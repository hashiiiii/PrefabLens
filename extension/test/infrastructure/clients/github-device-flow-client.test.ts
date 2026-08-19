import { describe, expect, it } from "vitest";
import { err, ok } from "../../../src/domain/result";
import { createGithubDeviceFlowGateway } from "../../../src/infrastructure/clients/github-device-flow-client";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

class VirtualClock {
  now = 0;

  sleep = async (milliseconds: number) => {
    this.now += milliseconds;
  };
}

describe("createGithubDeviceFlowGateway", () => {
  it("maps a successful device-code response", async () => {
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/device/code") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      expect(init?.method).toBe("POST");
      expect(new Headers(init?.headers).get("accept")).toBe("application/json");
      expect(init?.credentials).toBe("omit");
      const form = new URLSearchParams(String(init?.body));
      expect(form.get("client_id")).toBe("Ov23liYYM6t34p7Hxkc1");
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

    await expect(auth.requestDeviceCode()).resolves.toEqual(
      ok({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    );
  });

  it("returns a failure for a device-code HTTP error", async () => {
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/device/code") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      return json({}, 500);
    }) as typeof fetch;

    await expect(createGithubDeviceFlowGateway(route).requestDeviceCode()).resolves.toEqual(
      err({ kind: "device-flow-failed", message: "device code request failed (HTTP 500)" }),
    );
  });

  it("returns the device-code error description", async () => {
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/device/code") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
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
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      expect(clock.now).toBe(5_000);
      expect(init?.method).toBe("POST");
      expect(new Headers(init?.headers).get("accept")).toBe("application/json");
      expect(init?.credentials).toBe("omit");
      const form = new URLSearchParams(String(init?.body));
      expect(form.get("client_id")).toBe("Ov23liYYM6t34p7Hxkc1");
      expect(form.get("device_code")).toBe("dc1");
      expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:device_code");
      return json({ access_token: "tok123" });
    }) as typeof fetch;

    const result = await createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
      deviceCode: "dc1",
      userCode: "ABCD-1234",
      verificationUri: "https://github.com/login/device",
      interval: 5,
      expiresIn: 900,
    });

    expect(result).toEqual({ status: "ok", token: "tok123" });
    expect(clock.now).toBe(5_000);
  });

  it("repeats with the same interval after authorization_pending", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      if (clock.now === 5_000 || clock.now === 10_000) return json({ error: "authorization_pending" });
      if (clock.now === 15_000) return json({ access_token: "tok123" });
      throw new Error(`Unexpected poll time: ${clock.now}`);
    }) as typeof fetch;

    const result = await createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
      deviceCode: "dc1",
      userCode: "ABCD-1234",
      verificationUri: "https://github.com/login/device",
      interval: 5,
      expiresIn: 900,
    });

    expect(result).toEqual({ status: "ok", token: "tok123" });
    expect(clock.now).toBe(15_000);
  });

  it("uses the response interval after slow_down", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      if (clock.now === 5_000) return json({ error: "slow_down", interval: 8 });
      if (clock.now === 13_000) return json({ access_token: "tok123" });
      throw new Error(`Unexpected poll time: ${clock.now}`);
    }) as typeof fetch;

    await expect(
      createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    ).resolves.toEqual({ status: "ok", token: "tok123" });
    expect(clock.now).toBe(13_000);
  });

  it("adds five seconds when slow_down has no interval", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      if (clock.now === 5_000) return json({ error: "slow_down" });
      if (clock.now === 15_000) return json({ access_token: "tok123" });
      throw new Error(`Unexpected poll time: ${clock.now}`);
    }) as typeof fetch;

    await expect(
      createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    ).resolves.toEqual({ status: "ok", token: "tok123" });
    expect(clock.now).toBe(15_000);
  });

  it("maps expired_token to expired", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      expect(clock.now).toBe(5_000);
      return json({ error: "expired_token" });
    }) as typeof fetch;

    await expect(
      createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    ).resolves.toEqual({ status: "expired" });
  });

  it("maps access_denied to denied", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      expect(clock.now).toBe(5_000);
      return json({ error: "access_denied" });
    }) as typeof fetch;

    await expect(
      createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    ).resolves.toEqual({ status: "denied" });
  });

  it("maps incorrect_client_credentials to failed", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      expect(clock.now).toBe(5_000);
      return json({ error: "incorrect_client_credentials" });
    }) as typeof fetch;

    await expect(
      createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    ).resolves.toEqual({ status: "failed" });
  });

  it("maps a token HTTP error to failed", async () => {
    const clock = new VirtualClock();
    const route = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url !== "https://github.com/login/oauth/access_token") {
        throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
      }
      expect(clock.now).toBe(5_000);
      return json({}, 500);
    }) as typeof fetch;

    await expect(
      createGithubDeviceFlowGateway(route, clock.sleep).pollForToken({
        deviceCode: "dc1",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
        interval: 5,
        expiresIn: 900,
      }),
    ).resolves.toEqual({ status: "failed" });
  });
});
