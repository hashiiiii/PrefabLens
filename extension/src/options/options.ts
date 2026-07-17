import { type DeviceCode, type PollResult, pollForToken, requestDeviceCode } from "../github/deviceFlow";
import { GITHUB_ORIGIN, type Instances, permissionPatterns, scriptId } from "../github/hosts";
import { must } from "../util/must";

// Keep the form body on the TS side: options.html and the jsdom tests share the same markup.
export const OPTIONS_BODY = `
  <h1>PrefabLens</h1>
  <p id="signin-state"></p>
  <button id="signin" type="button">Sign in with GitHub</button>
  <div id="flow" hidden>
    <p>Code: <code id="user-code"></code></p>
    <p><a id="verify-link" href="#" target="_blank" rel="noopener noreferrer">Open GitHub</a></p>
    <button id="copy-code" type="button">Copy code</button>
  </div>
  <span id="status" role="status"></span>
  <h2>Enterprise instances</h2>
  <p>
    GitHub Enterprise Server or ghe.com: add the instance, then paste a personal access token
    with repo read access. Sign in with GitHub above covers github.com only.
  </p>
  <div>
    <input id="instance-origin" type="url" placeholder="https://github.example.com" />
    <button id="instance-add-button" type="button">Add instance</button>
  </div>
  <ul id="instance-list"></ul>
  <span id="instance-status" role="status"></span>
`;

type StorageLike = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

type ClipboardLike = {
  writeText(text: string): Promise<void>;
};

// Injectable bundle for the device flow: real implementations (fetch/sleep/navigator.clipboard) are
// bound once at the chrome bootstrap below, so initOptions itself never touches real I/O.
export type SignInFlow = {
  requestDeviceCode(): Promise<DeviceCode>;
  pollForToken(code: DeviceCode): Promise<PollResult>;
  clipboard: ClipboardLike;
};

// Chrome permission/registration side effects, injected so jsdom tests stay chrome-free.
export type InstanceIo = {
  requestPermission(patterns: string[]): Promise<boolean>;
  removePermission(patterns: string[]): Promise<void>;
  registerScript(origin: string): Promise<void>;
  unregisterScript(origin: string): Promise<void>;
};

export async function initOptions(
  doc: Document,
  storage: StorageLike,
  flow: SignInFlow,
  instanceIo: InstanceIo,
): Promise<void> {
  const signinState = must(doc.querySelector<HTMLElement>("#signin-state"));
  const signinButton = must(doc.querySelector<HTMLButtonElement>("#signin"));
  const flowArea = must(doc.querySelector<HTMLElement>("#flow"));
  const userCode = must(doc.querySelector<HTMLElement>("#user-code"));
  const verifyLink = must(doc.querySelector<HTMLAnchorElement>("#verify-link"));
  const copyButton = must(doc.querySelector<HTMLButtonElement>("#copy-code"));
  const status = must(doc.querySelector<HTMLElement>("#status"));

  const showSignedIn = (pat: unknown): void => {
    signinState.textContent = pat ? "Signed in" : "Not signed in";
  };

  const stored = await storage.get(["pat"]);
  showSignedIn(stored.pat);

  signinButton.addEventListener("click", () => {
    void (async () => {
      // The poll can run for minutes; disabling the button while in flight makes concurrent flows impossible
      signinButton.disabled = true;
      status.textContent = "";
      try {
        const code = await flow.requestDeviceCode();
        userCode.textContent = code.userCode;
        verifyLink.href = code.verificationUri;
        flowArea.hidden = false;

        const result = await flow.pollForToken(code);
        if (result.status === "ok") {
          await storage.set({ pat: result.token });
          showSignedIn(result.token);
        } else if (result.status === "denied") {
          status.textContent = "Authorization denied";
        } else {
          status.textContent = "Code expired — try again";
        }
      } catch {
        status.textContent = "Sign-in failed";
      } finally {
        // The code is consumed once the poll ends, whatever the outcome: hide it and allow a retry
        flowArea.hidden = true;
        signinButton.disabled = false;
      }
    })();
  });

  copyButton.addEventListener("click", () => {
    void flow.clipboard.writeText(userCode.textContent ?? "");
  });

  const originInput = must(doc.querySelector<HTMLInputElement>("#instance-origin"));
  const addButton = must(doc.querySelector<HTMLButtonElement>("#instance-add-button"));
  const list = must(doc.querySelector<HTMLUListElement>("#instance-list"));
  const instanceStatus = must(doc.querySelector<HTMLElement>("#instance-status"));

  const loadInstances = async (): Promise<Instances> =>
    ((await storage.get(["instances"])).instances as Instances | undefined) ?? {};

  // Instance rows are built with createElement/textContent only: origins are user input.
  const renderInstances = (instances: Instances): void => {
    list.textContent = "";
    for (const [origin, entry] of Object.entries(instances)) {
      const item = doc.createElement("li");
      item.setAttribute("data-origin", origin);
      const label = doc.createElement("code");
      label.textContent = origin;
      const pat = doc.createElement("input");
      pat.type = "password";
      pat.placeholder = "Personal access token";
      const state = doc.createElement("span");
      state.textContent = entry.pat ? "Token set" : "No token";
      const save = doc.createElement("button");
      save.type = "button";
      save.setAttribute("data-save", "");
      save.textContent = "Save token";
      save.addEventListener("click", () => {
        void (async () => {
          const current = await loadInstances();
          await storage.set({ instances: { ...current, [origin]: { pat: pat.value } } });
          pat.value = ""; // consumed: never keep the token visible in the form
          state.textContent = "Token set";
        })();
      });
      const remove = doc.createElement("button");
      remove.type = "button";
      remove.setAttribute("data-remove", "");
      remove.textContent = "Remove";
      remove.addEventListener("click", () => {
        void (async () => {
          await instanceIo.unregisterScript(origin);
          await instanceIo.removePermission(permissionPatterns(origin));
          const { [origin]: _gone, ...rest } = await loadInstances();
          await storage.set({ instances: rest });
          renderInstances(rest);
        })();
      });
      item.append(label, pat, save, remove, state);
      list.append(item);
    }
  };

  addButton.addEventListener("click", () => {
    void (async () => {
      instanceStatus.textContent = "";
      // Everything before requestPermission stays synchronous: the permission prompt
      // must be reachable from the click's transient user gesture.
      let origin: string;
      try {
        const url = new URL(originInput.value.trim());
        if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("scheme");
        origin = url.origin;
      } catch {
        instanceStatus.textContent = "Enter the instance URL, like https://github.example.com";
        return;
      }
      if (origin === GITHUB_ORIGIN) {
        instanceStatus.textContent = "github.com works out of the box — use Sign in with GitHub above";
        return;
      }
      const granted = await instanceIo.requestPermission(permissionPatterns(origin));
      if (!granted) {
        instanceStatus.textContent = "Permission was not granted";
        return;
      }
      await instanceIo.registerScript(origin);
      const current = await loadInstances();
      const next = { ...current, [origin]: current[origin] ?? {} };
      await storage.set({ instances: next });
      originInput.value = "";
      renderInstances(next);
    })();
  });

  renderInstances(await loadInstances());
}

if (typeof chrome !== "undefined" && chrome.storage) {
  document.body.innerHTML = OPTIONS_BODY;
  const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
  void initOptions(
    document,
    chrome.storage.local,
    {
      requestDeviceCode: () => requestDeviceCode(fetch),
      pollForToken: (code) => pollForToken(fetch, sleep, code),
      clipboard: navigator.clipboard,
    },
    {
      requestPermission: (patterns) => chrome.permissions.request({ origins: patterns }),
      removePermission: async (patterns) => {
        await chrome.permissions.remove({ origins: patterns }).catch(() => {});
      },
      registerScript: async (origin) => {
        const existing = await chrome.scripting.getRegisteredContentScripts({ ids: [scriptId(origin)] });
        if (existing.length) return; // re-adding an instance must not double-register
        await chrome.scripting.registerContentScripts([
          {
            id: scriptId(origin),
            matches: [`${origin}/*`],
            js: ["content.js"],
            runAt: "document_idle",
            persistAcrossSessions: true,
          },
        ]);
      },
      unregisterScript: async (origin) => {
        await chrome.scripting.unregisterContentScripts({ ids: [scriptId(origin)] }).catch(() => {});
      },
    },
  );
}
