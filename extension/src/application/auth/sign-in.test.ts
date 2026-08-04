import { describe, expect, it } from "vitest";
import type { PendingSignIn } from "../../domain/auth/token";
import type { TokenRepository } from "../../domain/auth/token-repository";
import { err, ok } from "../../domain/result";
import type { DeviceCode, GithubAuthGateway, PollResult } from "../gateway/github-auth";
import { type SignInFailure, signIn } from "./sign-in";

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
  const urls: string[] = [];
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
  const openTab = (url: string) => {
    calls.push("openTab");
    urls.push(url);
  };
  const now = () => 1_000;
  return { auth, tokenStore, fetchFn, sleep, openTab, now, calls, pendings, tokens, urls };
}

function fakeUi() {
  const pending: Array<{ userCode: string; verificationUri: string }> = [];
  const failures: SignInFailure[] = [];
  const ui = {
    showPending: (userCode: string, verificationUri: string) => void pending.push({ userCode, verificationUri }),
    showFailure: (reason: SignInFailure) => void failures.push(reason),
  };
  return { ui, pending, failures };
}

describe("signIn", () => {
  it("saves the pending code, opens the tab, and stores the token on success", async () => {
    const { auth, tokenStore, fetchFn, sleep, openTab, now, pendings, tokens, urls, calls } = fakeDeps(async () => ({
      status: "ok",
      token: "tok123",
    }));
    const { ui, pending, failures } = fakeUi();
    const state = { inFlight: false };
    await signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui);
    // expiresAt derives from the injected now(): 1000 + 900s in ms.
    expect(pendings).toEqual([{ userCode: "ABCD-1234", expiresAt: 901_000 }]);
    expect(pending).toEqual([{ userCode: "ABCD-1234", verificationUri: "https://github.com/login/device" }]);
    expect(urls).toEqual(["https://github.com/login/device"]);
    expect(tokens).toEqual(["tok123"]);
    expect(failures).toEqual([]);
    // The pending record must be saved before the tab opens (the device page reads it on load).
    expect(calls.indexOf("savePending")).toBeLessThan(calls.indexOf("openTab"));
    expect(calls).toContain("clearPending");
  });

  it("reports denied without storing a token", async () => {
    const { auth, tokenStore, fetchFn, sleep, openTab, now, tokens, calls } = fakeDeps(async () => ({
      status: "denied",
    }));
    const { ui, failures } = fakeUi();
    const state = { inFlight: false };
    await signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui);
    expect(failures).toEqual(["denied"]);
    expect(tokens).toEqual([]);
    expect(calls).toContain("clearPending");
  });

  it("reports expired", async () => {
    const { auth, tokenStore, fetchFn, sleep, openTab, now } = fakeDeps(async () => ({ status: "expired" }));
    const { ui, failures } = fakeUi();
    const state = { inFlight: false };
    await signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui);
    expect(failures).toEqual(["expired"]);
  });

  it("reports the generic failure when the code request fails", async () => {
    const { auth, tokenStore, fetchFn, sleep, openTab, now, calls } = fakeDeps(async () => ({
      status: "ok",
      token: "t",
    }));
    auth.requestDeviceCode = async () => err({ kind: "device-flow-failed", message: "network down" });
    const { ui, failures } = fakeUi();
    const state = { inFlight: false };
    await signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui);
    expect(failures).toEqual(["failed"]);
    expect(calls).not.toContain("openTab");
  });

  it("ignores a second start while a flow is polling", async () => {
    let resolvePoll!: (r: PollResult) => void;
    const { auth, tokenStore, fetchFn, sleep, openTab, now, calls } = fakeDeps(
      () => new Promise<PollResult>((resolve) => (resolvePoll = resolve)),
    );
    const { ui } = fakeUi();
    const state = { inFlight: false };
    const first = signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui);
    await signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui); // resolves immediately: the guard rejects re-entry
    expect(calls.filter((c) => c === "request")).toHaveLength(1);
    // Drain microtasks until the first flow reaches the poll, so resolvePoll is assigned.
    for (let i = 0; i < 10 && !calls.includes("poll"); i++) await Promise.resolve();
    resolvePoll({ status: "ok", token: "tok" });
    await first;
    // With the first flow settled, a new one can start (its poll stays pending). Only the guard matters here.
    void signIn(auth, tokenStore, fetchFn, sleep, openTab, now, state, ui);
    expect(calls.filter((c) => c === "request")).toHaveLength(2);
  });
});
