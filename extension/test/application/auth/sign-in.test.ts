import { describe, expect, it } from "vitest";
import { type SignInEvent, signIn } from "../../../src/application/auth/sign-in";
import { createChromeAuthRepository } from "../../../src/infrastructure/clients/chrome-auth-client";
import { createGithubDeviceFlowGateway } from "../../../src/infrastructure/clients/github-device-flow-client";
import type { JsonValue } from "../../../src/internal/json";
import { MemoryStorageArea } from "../../support/memory-storage-area";

const json = (body: JsonValue, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

class VirtualClock {
  now = 0;

  sleep = async (milliseconds: number) => {
    this.now += milliseconds;
  };
}

async function collect(events: AsyncGenerator<SignInEvent>): Promise<SignInEvent[]> {
  const collected: SignInEvent[] = [];
  for await (const event of events) collected.push(event);
  return collected;
}

describe("signIn", () => {
  it("completes sign-in after it emits the device code", async () => {
    const area = new MemoryStorageArea();
    const authRepository = createChromeAuthRepository(area);
    const clock = new VirtualClock();
    const route: typeof fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "https://github.com/login/device/code") {
        return json({
          device_code: "dc1",
          user_code: "ABCD-1234",
          verification_uri: "https://github.com/login/device",
          interval: 5,
          expires_in: 900,
        });
      }
      if (url === "https://github.com/login/oauth/access_token" && clock.now === 5_000) {
        return json({ access_token: "tok123" });
      }
      throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url} at ${clock.now}`);
    };
    const auth = createGithubDeviceFlowGateway(route, clock.sleep);
    const state = { inFlight: false };
    const events = signIn(auth, authRepository, () => 1_000, state);

    await expect(events.next()).resolves.toEqual({
      done: false,
      value: {
        status: "pending",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
      },
    });
    expect(await authRepository.loadPendingSignIn()).toEqual({ userCode: "ABCD-1234", expiresAt: 901_000 });

    expect(await collect(events)).toEqual([{ status: "ok" }]);
    expect(await authRepository.loadAccessToken()).toBe("tok123");
    expect(await authRepository.loadPendingSignIn()).toBeUndefined();
    expect(state.inFlight).toBe(false);
  });

  it("emits a request failure and clears in-flight state", async () => {
    const authRepository = createChromeAuthRepository(new MemoryStorageArea());
    const route: typeof fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "https://github.com/login/device/code") return json({}, 500);
      throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url}`);
    };
    const state = { inFlight: false };

    const events = await collect(signIn(createGithubDeviceFlowGateway(route), authRepository, () => 1_000, state));

    expect(events).toEqual([{ status: "failed", reason: "failed" }]);
    expect(state.inFlight).toBe(false);
  });

  it("emits one terminal denied result", async () => {
    const authRepository = createChromeAuthRepository(new MemoryStorageArea());
    const clock = new VirtualClock();
    const route: typeof fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "https://github.com/login/device/code") {
        return json({
          device_code: "dc1",
          user_code: "ABCD-1234",
          verification_uri: "https://github.com/login/device",
          interval: 5,
          expires_in: 900,
        });
      }
      if (url === "https://github.com/login/oauth/access_token" && clock.now === 5_000) {
        return json({ error: "access_denied" });
      }
      throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url} at ${clock.now}`);
    };
    const state = { inFlight: false };

    const events = await collect(
      signIn(createGithubDeviceFlowGateway(route, clock.sleep), authRepository, () => 1_000, state),
    );

    expect(events).toEqual([
      { status: "pending", userCode: "ABCD-1234", verificationUri: "https://github.com/login/device" },
      { status: "failed", reason: "denied" },
    ]);
    expect(await authRepository.loadAccessToken()).toBeUndefined();
    expect(await authRepository.loadPendingSignIn()).toBeUndefined();
  });

  it("clears pending sign-in data after an unexpected token request rejection", async () => {
    const authRepository = createChromeAuthRepository(new MemoryStorageArea());
    const clock = new VirtualClock();
    const route: typeof fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "https://github.com/login/device/code") {
        return json({
          device_code: "dc1",
          user_code: "ABCD-1234",
          verification_uri: "https://github.com/login/device",
          interval: 5,
          expires_in: 900,
        });
      }
      if (url === "https://github.com/login/oauth/access_token" && clock.now === 5_000) {
        throw new Error("token request rejected");
      }
      throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url} at ${clock.now}`);
    };
    const state = { inFlight: false };
    const events = signIn(createGithubDeviceFlowGateway(route, clock.sleep), authRepository, () => 1_000, state);

    await expect(events.next()).resolves.toEqual({
      done: false,
      value: {
        status: "pending",
        userCode: "ABCD-1234",
        verificationUri: "https://github.com/login/device",
      },
    });
    expect(await authRepository.loadPendingSignIn()).toEqual({ userCode: "ABCD-1234", expiresAt: 901_000 });

    await expect(events.next()).resolves.toEqual({ done: false, value: { status: "failed", reason: "failed" } });
    await expect(events.next()).resolves.toEqual({ done: true, value: undefined });
    expect(await authRepository.loadAccessToken()).toBeUndefined();
    expect(await authRepository.loadPendingSignIn()).toBeUndefined();
    expect(state.inFlight).toBe(false);
  });

  it("rejects a concurrent second start while the first request remains pending", async () => {
    const authRepository = createChromeAuthRepository(new MemoryStorageArea());
    const clock = new VirtualClock();
    const codeRequest = Promise.withResolvers<Response>();
    const route: typeof fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url === "https://github.com/login/device/code") return codeRequest.promise;
      if (url === "https://github.com/login/oauth/access_token" && clock.now === 5_000) {
        return json({ access_token: "tok123" });
      }
      throw new Error(`Unexpected request: ${init?.method ?? "GET"} ${url} at ${clock.now}`);
    };
    const auth = createGithubDeviceFlowGateway(route, clock.sleep);
    const state = { inFlight: false };

    const first = collect(signIn(auth, authRepository, () => 1_000, state));
    await Promise.resolve();

    expect(state.inFlight).toBe(true);
    expect(await collect(signIn(auth, authRepository, () => 1_000, state))).toEqual([]);

    codeRequest.resolve(
      json({
        device_code: "dc1",
        user_code: "ABCD-1234",
        verification_uri: "https://github.com/login/device",
        interval: 5,
        expires_in: 900,
      }),
    );
    expect(await first).toEqual([
      { status: "pending", userCode: "ABCD-1234", verificationUri: "https://github.com/login/device" },
      { status: "ok" },
    ]);
    expect(state.inFlight).toBe(false);
  });
});
