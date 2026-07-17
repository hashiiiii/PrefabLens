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

// Records permission/registration calls; grant=false simulates the user declining Chrome's prompt.
function fakeInstanceIo(grant = true) {
  const granted: string[][] = [];
  const removed: string[][] = [];
  const registered: string[] = [];
  const unregistered: string[] = [];
  return {
    granted,
    removed,
    registered,
    unregistered,
    async requestPermission(patterns: string[]) {
      granted.push(patterns);
      return grant;
    },
    async removePermission(patterns: string[]) {
      removed.push(patterns);
    },
    async registerScript(origin: string) {
      registered.push(origin);
    },
    async unregisterScript(origin: string) {
      unregistered.push(origin);
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
      fakeInstanceIo(),
    );
    expect(document.querySelector("#signin-state")?.textContent).toBe("Signed in");
  });

  it("shows Not signed in when no pat is stored", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    await initOptions(
      document,
      fakeStorage(),
      fakeFlow(async () => ({ status: "ok", token: "tok" })),
      fakeInstanceIo(),
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
      fakeInstanceIo(),
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
      fakeInstanceIo(),
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
      fakeInstanceIo(),
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
      fakeInstanceIo(),
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
      fakeInstanceIo(),
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
      fakeInstanceIo(),
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
    await initOptions(document, fakeStorage(), flow, fakeInstanceIo());
    document.querySelector<HTMLButtonElement>("#signin")?.click();
    await flush();
    document.querySelector<HTMLButtonElement>("#copy-code")?.click();
    await flush();
    expect(flow.clipboard.writes).toEqual(["ABCD-1234"]);
  });
});

describe("enterprise instances", () => {
  const denied = () => fakeFlow(async () => ({ status: "denied" }));

  it("adds an instance: permission request, script registration, storage entry", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    const io = fakeInstanceIo();
    await initOptions(document, storage, denied(), io);
    // input beyond the origin is normalized away
    must(document.querySelector<HTMLInputElement>("#instance-origin")).value = "https://github.example.com/some/page";
    must(document.querySelector<HTMLButtonElement>("#instance-add-button")).click();
    await flush();
    // GHES needs only its own origin pattern (the API is same-origin under /api/v3)
    expect(io.granted).toEqual([["https://github.example.com/*"]]);
    expect(io.registered).toEqual(["https://github.example.com"]);
    expect(storage.data.instances).toEqual({ "https://github.example.com": {} });
    expect(document.querySelector('[data-origin="https://github.example.com"]')).not.toBeNull();
  });

  it("rejects github.com and invalid input without requesting permission", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const io = fakeInstanceIo();
    await initOptions(document, fakeStorage(), denied(), io);
    for (const value of ["https://github.com", "not a url"]) {
      must(document.querySelector<HTMLInputElement>("#instance-origin")).value = value;
      must(document.querySelector<HTMLButtonElement>("#instance-add-button")).click();
      await flush();
      // each rejection explains itself instead of silently doing nothing
      expect(document.querySelector("#instance-status")?.textContent).not.toBe("");
    }
    expect(io.granted).toEqual([]);
  });

  it("keeps the instance out of storage when the permission is declined", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage();
    const io = fakeInstanceIo(false);
    await initOptions(document, storage, denied(), io);
    must(document.querySelector<HTMLInputElement>("#instance-origin")).value = "https://github.example.com";
    must(document.querySelector<HTMLButtonElement>("#instance-add-button")).click();
    await flush();
    expect(io.registered).toEqual([]);
    expect(storage.data.instances).toBeUndefined();
  });

  it("saves a PAT for a listed instance", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage({ instances: { "https://github.example.com": {} } });
    await initOptions(document, storage, denied(), fakeInstanceIo());
    const item = must(document.querySelector('[data-origin="https://github.example.com"]'));
    must(item.querySelector<HTMLInputElement>("input[type=password]")).value = "ghp_x";
    must(item.querySelector<HTMLButtonElement>("[data-save]")).click();
    await flush();
    expect((storage.data.instances as Record<string, { pat?: string }>)["https://github.example.com"]?.pat).toBe(
      "ghp_x",
    );
  });

  it("removes an instance: unregister, permission removal, storage cleanup", async () => {
    document.body.innerHTML = OPTIONS_BODY;
    const storage = fakeStorage({ instances: { "https://acme.ghe.com": { pat: "t" } } });
    const io = fakeInstanceIo();
    await initOptions(document, storage, denied(), io);
    const item = must(document.querySelector('[data-origin="https://acme.ghe.com"]'));
    must(item.querySelector<HTMLButtonElement>("[data-remove]")).click();
    await flush();
    expect(io.unregistered).toEqual(["https://acme.ghe.com"]);
    // ghe.com carries the extra api-subdomain pattern granted at add time
    expect(io.removed).toEqual([["https://acme.ghe.com/*", "https://api.acme.ghe.com/*"]]);
    expect(storage.data.instances).toEqual({});
    expect(document.querySelector('[data-origin="https://acme.ghe.com"]')).toBeNull();
  });
});
