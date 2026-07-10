import { describe, expect, it } from "vitest";
import type { DeviceCode, PollResult } from "../github/deviceFlow";
import { createSignIn, FAILURE_TEXT, type PendingSignIn, type SignInIo, type SignInUi } from "./signin";

const CODE: DeviceCode = {
  deviceCode: "dc1",
  userCode: "ABCD-1234",
  verificationUri: "https://github.com/login/device",
  interval: 5,
  expiresIn: 900,
};

// Recording io fake: every hook appends its name to `calls` so tests can assert both effects and order.
function fakeIo(poll: () => Promise<PollResult>) {
  const calls: string[] = [];
  const pendings: PendingSignIn[] = [];
  const tokens: string[] = [];
  const urls: string[] = [];
  const io: SignInIo = {
    async requestDeviceCode() {
      calls.push("request");
      return CODE;
    },
    pollForToken() {
      calls.push("poll");
      return poll();
    },
    async savePending(pending) {
      calls.push("savePending");
      pendings.push(pending);
    },
    async clearPending() {
      calls.push("clearPending");
    },
    async saveToken(token) {
      calls.push("saveToken");
      tokens.push(token);
    },
    openTab(url) {
      calls.push("openTab");
      urls.push(url);
    },
    now: () => 1_000,
  };
  return { io, calls, pendings, tokens, urls };
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

describe("createSignIn", () => {
  it("saves the pending code, opens the tab, and stores the token on success", async () => {
    const { io, pendings, tokens, urls, calls } = fakeIo(async () => ({ status: "ok", token: "tok123" }));
    const { ui, pending, failures } = fakeUi();
    await createSignIn(io)(ui);
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
    const { io, tokens, calls } = fakeIo(async () => ({ status: "denied" }));
    const { ui, failures } = fakeUi();
    await createSignIn(io)(ui);
    expect(failures).toEqual([FAILURE_TEXT.denied]);
    expect(tokens).toEqual([]);
    expect(calls).toContain("clearPending");
  });

  it("maps expired to its failure copy", async () => {
    const { io } = fakeIo(async () => ({ status: "expired" }));
    const { ui, failures } = fakeUi();
    await createSignIn(io)(ui);
    expect(failures).toEqual([FAILURE_TEXT.expired]);
  });

  it("shows the generic failure when the code request throws", async () => {
    const { io, calls } = fakeIo(async () => ({ status: "ok", token: "t" }));
    io.requestDeviceCode = async () => {
      throw new Error("network down");
    };
    const { ui, failures } = fakeUi();
    await createSignIn(io)(ui);
    expect(failures).toEqual([FAILURE_TEXT.failed]);
    expect(calls).not.toContain("openTab");
  });

  it("ignores a second start while a flow is polling", async () => {
    let resolvePoll!: (r: PollResult) => void;
    const { io, calls } = fakeIo(() => new Promise<PollResult>((resolve) => (resolvePoll = resolve)));
    const { ui } = fakeUi();
    const signIn = createSignIn(io);
    const first = signIn(ui);
    await signIn(ui); // resolves immediately: the guard rejects re-entry
    expect(calls.filter((c) => c === "request")).toHaveLength(1);
    // Drain microtasks until the first flow reaches the poll, so resolvePoll is assigned.
    for (let i = 0; i < 10 && !calls.includes("poll"); i++) await Promise.resolve();
    resolvePoll({ status: "ok", token: "tok" });
    await first;
    // With the first flow settled, a new one may start (its poll stays pending; only the guard matters here).
    void signIn(ui);
    expect(calls.filter((c) => c === "request")).toHaveLength(2);
  });
});
