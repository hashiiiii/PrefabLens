import { type DeviceCode, type PollResult, pollForToken, requestDeviceCode } from "../github/deviceFlow";
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

export async function initOptions(doc: Document, storage: StorageLike, flow: SignInFlow): Promise<void> {
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
}

if (typeof chrome !== "undefined" && chrome.storage) {
  document.body.innerHTML = OPTIONS_BODY;
  const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
  void initOptions(document, chrome.storage.local, {
    requestDeviceCode: () => requestDeviceCode(fetch),
    pollForToken: (code) => pollForToken(fetch, sleep, code),
    clipboard: navigator.clipboard,
  });
}
