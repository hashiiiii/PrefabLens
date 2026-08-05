import { describe, expect, it } from "vitest";
import type { PendingSignIn } from "../../domain/auth/token";
import type { TokenRepository } from "../../domain/auth/token-repository";
import { err, ok } from "../../domain/result";
import type { DeviceCode, GithubAuthGateway, PollResult } from "../gateway/github-auth";
import { signIn } from "./sign-in";

const CODE: DeviceCode = {
  deviceCode: "dc1",
  userCode: "ABCD-1234",
  verificationUri: "https://github.com/login/device",
  interval: 5,
  expiresIn: 900,
};

// Recording fakes: every hook appends its name to `calls` so tests can assert both effects and order.
function fakeDeps(poll: () => Promise<PollResult>) {
  const calls: string[] = [];
  const pendings: PendingSignIn[] = [];
  const tokens: string[] = [];
  const auth: GithubAuthGateway = {
    async requestDeviceCode() {
      calls.push("request");
      return ok(CODE);
    },
    pollForToken() {
      calls.push("poll");
      return poll();
    },
  };
  const tokenStore: TokenRepository = {
    async readAccessToken() {
      return undefined;
    },
    async savePendingSignIn(pending) {
      calls.push("savePending");
      pendings.push(pending);
    },
    async readPendingSignIn() {
      return undefined;
    },
    async clearPendingSignIn() {
      calls.push("clearPending");
    },
    async saveAccessToken(token) {
      calls.push("saveToken");
      tokens.push(token);
    },
  };
  const fetchFn = fetch;
  const sleep = async () => {};
  const now = () => 1_000;
  return { auth, tokenStore, fetchFn, sleep, now, calls, pendings, tokens };
}

async function collect(gen: AsyncGenerator) {
  const events = [];
  for await (const event of gen) events.push(event);
  return events;
}

describe("signIn", () => {
  it("saves the pending code, yields pending, then stores the token on success", async () => {
    const { auth, tokenStore, fetchFn, sleep, now, pendings, tokens, calls } = fakeDeps(async () => ({
      status: "ok",
      token: "tok123",
    }));
    const state = { inFlight: false };
    const events = await collect(signIn(auth, tokenStore, fetchFn, sleep, now, state));
    // expiresAt derives from the injected now(): 1000 + 900s in ms.
    expect(pendings).toEqual([{ userCode: "ABCD-1234", expiresAt: 901_000 }]);
    expect(events).toEqual([
      { status: "pending", userCode: "ABCD-1234", verificationUri: "https://github.com/login/device" },
      { status: "ok" },
    ]);
    expect(tokens).toEqual(["tok123"]);
    // The pending record must be saved before pending is yielded (the device page reads it on load).
    expect(calls.indexOf("savePending")).toBeLessThan(calls.indexOf("poll"));
    expect(calls).toContain("clearPending");
  });

  it("reports denied without storing a token", async () => {
    const { auth, tokenStore, fetchFn, sleep, now, tokens, calls } = fakeDeps(async () => ({
      status: "denied",
    }));
    const state = { inFlight: false };
    const events = await collect(signIn(auth, tokenStore, fetchFn, sleep, now, state));
    expect(events).toContainEqual({ status: "failed", reason: "denied" });
    expect(tokens).toEqual([]);
    expect(calls).toContain("clearPending");
  });

  it("reports expired", async () => {
    const { auth, tokenStore, fetchFn, sleep, now } = fakeDeps(async () => ({ status: "expired" }));
    const state = { inFlight: false };
    const events = await collect(signIn(auth, tokenStore, fetchFn, sleep, now, state));
    expect(events).toContainEqual({ status: "failed", reason: "expired" });
  });

  it("reports the generic failure when the code request fails", async () => {
    const { auth, tokenStore, fetchFn, sleep, now, calls } = fakeDeps(async () => ({
      status: "ok",
      token: "t",
    }));
    auth.requestDeviceCode = async () => err({ kind: "device-flow-failed", message: "network down" });
    const state = { inFlight: false };
    const events = await collect(signIn(auth, tokenStore, fetchFn, sleep, now, state));
    expect(events).toEqual([{ status: "failed", reason: "failed" }]);
    expect(calls).not.toContain("poll");
  });

  it("ignores a second start while a flow is polling", async () => {
    let resolvePoll!: (r: PollResult) => void;
    const { auth, tokenStore, fetchFn, sleep, now, calls } = fakeDeps(
      () => new Promise<PollResult>((resolve) => (resolvePoll = resolve)),
    );
    const state = { inFlight: false };
    const first = collect(signIn(auth, tokenStore, fetchFn, sleep, now, state));
    await collect(signIn(auth, tokenStore, fetchFn, sleep, now, state)); // resolves immediately: the guard rejects re-entry
    expect(calls.filter((c) => c === "request")).toHaveLength(1);
    // Drain microtasks until the first flow reaches the poll, so resolvePoll is assigned.
    for (let i = 0; i < 10 && !calls.includes("poll"); i++) await Promise.resolve();
    resolvePoll({ status: "ok", token: "tok" });
    await first;
    // With the first flow settled, a new one can start (its poll stays pending). Only the guard matters here.
    void collect(signIn(auth, tokenStore, fetchFn, sleep, now, state));
    expect(calls.filter((c) => c === "request")).toHaveLength(2);
  });
});
