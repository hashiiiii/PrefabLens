import { describe, expect, it } from "vitest";
import type { DeviceCode, PollResult } from "../port/github-auth";
import { FAILURE_TEXT, type PendingSignIn, type SignInDeps, type SignInState, type SignInUi, signIn } from "./sign-in";

const CODE: DeviceCode = {
  deviceCode: "dc1",
  userCode: "ABCD-1234",
  verificationUri: "https://github.com/login/device",
  interval: 5,
  expiresIn: 900,
};

// Recording deps fake: every hook appends its name to `calls` so tests can assert both effects and order.
function fakeDeps(poll: () => Promise<PollResult>) {
  const calls: string[] = [];
  const pendings: PendingSignIn[] = [];
  const tokens: string[] = [];
  const urls: string[] = [];
  const deps: SignInDeps = {
    auth: {
      async requestDeviceCode() {
        calls.push("request");
        return CODE;
      },
      pollForToken() {
        calls.push("poll");
        return poll();
      },
    },
    tokenStore: {
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
    },
    fetchFn: fetch,
    sleep: async () => {},
    openTab(url) {
      calls.push("openTab");
      urls.push(url);
    },
    now: () => 1_000,
  };
  return { deps, calls, pendings, tokens, urls };
}

function fakeUi() {
  const pending: Array<{ userCode: string; verificationUri: string }> = [];
  const failures: string[] = [];
  const ui: SignInUi = {
    showPending: (userCode, verificationUri) => void pending.push({ userCode, verificationUri }),
    showFailure: (message) => void failures.push(message),
  };
  return { ui, pending, failures };
}

describe("signIn", () => {
  it("saves the pending code, opens the tab, and stores the token on success", async () => {
    const { deps, pendings, tokens, urls, calls } = fakeDeps(async () => ({ status: "ok", token: "tok123" }));
    const { ui, pending, failures } = fakeUi();
    const state: SignInState = { inFlight: false };
    await signIn(deps, state, ui);
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

  it("maps denied to its failure copy without storing a token", async () => {
    const { deps, tokens, calls } = fakeDeps(async () => ({ status: "denied" }));
    const { ui, failures } = fakeUi();
    const state: SignInState = { inFlight: false };
    await signIn(deps, state, ui);
    expect(failures).toEqual([FAILURE_TEXT.denied]);
    expect(tokens).toEqual([]);
    expect(calls).toContain("clearPending");
  });

  it("maps expired to its failure copy", async () => {
    const { deps } = fakeDeps(async () => ({ status: "expired" }));
    const { ui, failures } = fakeUi();
    const state: SignInState = { inFlight: false };
    await signIn(deps, state, ui);
    expect(failures).toEqual([FAILURE_TEXT.expired]);
  });

  it("shows the generic failure when the code request throws", async () => {
    const { deps, calls } = fakeDeps(async () => ({ status: "ok", token: "t" }));
    deps.auth.requestDeviceCode = async () => {
      throw new Error("network down");
    };
    const { ui, failures } = fakeUi();
    const state: SignInState = { inFlight: false };
    await signIn(deps, state, ui);
    expect(failures).toEqual([FAILURE_TEXT.failed]);
    expect(calls).not.toContain("openTab");
  });

  it("ignores a second start while a flow is polling", async () => {
    let resolvePoll!: (r: PollResult) => void;
    const { deps, calls } = fakeDeps(() => new Promise<PollResult>((resolve) => (resolvePoll = resolve)));
    const { ui } = fakeUi();
    const state: SignInState = { inFlight: false };
    const first = signIn(deps, state, ui);
    await signIn(deps, state, ui); // resolves immediately: the guard rejects re-entry
    expect(calls.filter((c) => c === "request")).toHaveLength(1);
    // Drain microtasks until the first flow reaches the poll, so resolvePoll is assigned.
    for (let i = 0; i < 10 && !calls.includes("poll"); i++) await Promise.resolve();
    resolvePoll({ status: "ok", token: "tok" });
    await first;
    // With the first flow settled, a new one may start (its poll stays pending; only the guard matters here).
    void signIn(deps, state, ui);
    expect(calls.filter((c) => c === "request")).toHaveLength(2);
  });
});
