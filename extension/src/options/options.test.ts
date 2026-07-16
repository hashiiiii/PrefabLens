// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import type { DeviceCode, PollResult } from "../github/deviceFlow";
import { must } from "../util/must";
import { initOptions, OPTIONS_BODY, type SignInFlow } from "./options";

function fakeStorage(initial: Record<string, unknown> = {}) {
  const data = { ...initial };
  return {
    data,
    async get(keys: string[]) {
      return Object.fromEntries(keys.filter((k) => k in data).map((k) => [k, data[k]]));
    },
    async set(items: Record<string, unknown>) {
      Object.assign(data, items);
    },
  };
}

function fakeClipboard() {
  const writes: string[] = [];
  return {
    writes,
    async writeText(text: string) {
      writes.push(text);
    },
  };
}

const code: DeviceCode = {
  deviceCode: "dc1",
  userCode: "ABCD-1234",
  verificationUri: "https://github.com/login/device",
  interval: 5,
  expiresIn: 900,
};

// Builds a fake flow: requestDeviceCode always resolves to the canned code above (unless overridden),
// pollForToken resolves to whatever result the test wants, and clipboard writes are recorded for assertions.
function fakeFlow(
  pollForToken: () => Promise<PollResult>,
  requestDeviceCode: () => Promise<DeviceCode> = async () => code,
): SignInFlow & { clipboard: { writes: string[] } } {
  return { requestDeviceCode, pollForToken, clipboard: fakeClipboard() };
}

// Wait for the click handler's async chain (request -> render -> poll -> store) to finish (flush via a macrotask)
const flush = () => new Promise((r) => setTimeout(r, 0));

describe("initOptions", () => {
  it("shows Signed in when a pat is already stored", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    await initOptions(
      document,
      fakeStorage({ pat: "tok" }),
      fakeFlow(async () => ({ status: "ok", token: "tok" })),
    );
    expect(document.querySelector("#signin-state")?.textContent).toBe("Signed in");
  });

  it("shows Not signed in when no pat is stored", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    await initOptions(
      document,
      fakeStorage(),
      fakeFlow(async () => ({ status: "ok", token: "tok" })),
    );
    expect(document.querySelector("#signin-state")?.textContent).toBe("Not signed in");
  });

  it("renders the code on sign-in and stores the token once the poll succeeds", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(
      document,
      storage,
      fakeFlow(async () => ({ status: "ok", token: "tok123" })),
    );
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    expect(document.querySelector("#user-code")?.textContent).toBe("ABCD-1234");
    expect(document.querySelector<HTMLAnchorElement>("#verify-link")?.href).toBe("https://github.com/login/device");
    expect(storage.data.pat).toBe("tok123");
    expect(document.querySelector("#signin-state")?.textContent).toBe("Signed in");
    expect(document.querySelector<HTMLElement>("#flow")?.hidden).toBe(true);
  });

  it("shows Authorization denied when the user declines", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(
      document,
      storage,
      fakeFlow(async () => ({ status: "denied" })),
    );
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    expect(document.querySelector("#status")?.textContent).toBe("Authorization denied");
    expect(storage.data.pat).toBeUndefined();
    // The denied code is consumed: the flow area must not keep showing it
    expect(document.querySelector<HTMLElement>("#flow")?.hidden).toBe(true);
  });

  it("shows an expiry message when the code times out", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(
      document,
      storage,
      fakeFlow(async () => ({ status: "expired" })),
    );
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    expect(document.querySelector("#status")?.textContent).toBe("Code expired — try again");
    expect(storage.data.pat).toBeUndefined();
    // The expired code is consumed: the flow area must not keep showing it
    expect(document.querySelector<HTMLElement>("#flow")?.hidden).toBe(true);
  });

  it("shows a failure message when requesting the device code throws", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    await initOptions(
      document,
      storage,
      fakeFlow(
        async () => ({ status: "ok", token: "unreached" }),
        async () => {
          throw new Error("network down");
        },
      ),
    );
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    expect(document.querySelector("#status")?.textContent).toBe("Sign-in failed");
    expect(storage.data.pat).toBeUndefined();
  });

  it("hides the flow area and reports failure when the poll throws after the code rendered", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    // Hand-rolled deferred: lets the test observe the visible flow area before failing the poll
    let rejectPoll!: (err: Error) => void;
    const pending = new Promise<PollResult>((_resolve, reject) => {
      rejectPoll = reject;
    });
    await initOptions(
      document,
      storage,
      fakeFlow(() => pending),
    );
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    // Device code succeeded: the code is rendered and the flow area is visible while the poll runs
    expect(document.querySelector("#user-code")?.textContent).toBe("ABCD-1234");
    expect(document.querySelector<HTMLElement>("#flow")?.hidden).toBe(false);
    rejectPoll(new Error("network down"));
    await flush();
    expect(document.querySelector("#status")?.textContent).toBe("Sign-in failed");
    expect(storage.data.pat).toBeUndefined();
    // The consumed code must disappear once the flow ends
    expect(document.querySelector<HTMLElement>("#flow")?.hidden).toBe(true);
  });

  it("disables the sign-in button while the poll is in flight and re-enables it on failure", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    // Hand-rolled deferred: keeps the poll unresolved so the mid-flight disabled state is observable
    let resolvePoll!: (result: PollResult) => void;
    const pending = new Promise<PollResult>((resolve) => {
      resolvePoll = resolve;
    });
    await initOptions(
      document,
      fakeStorage(),
      fakeFlow(() => pending),
    );
    const signin = must(document.querySelector<HTMLButtonElement>("#signin"));
    signin.click();
    await flush();
    // Poll still unresolved: a second click must be impossible
    expect(signin.disabled).toBe(true);
    resolvePoll({ status: "denied" });
    await flush();
    // Flow ended (failure outcome): the user can try again
    expect(signin.disabled).toBe(false);
  });

  it("copies the user code to the clipboard", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const flow = fakeFlow(async () => ({ status: "denied" }));
    await initOptions(document, fakeStorage(), flow);
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    document.querySelector<HTMLButtonElement>("#copy-code")?.click();
    await flush();
    expect(flow.clipboard.writes).toEqual(["ABCD-1234"]);
  });
});
