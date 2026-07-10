// Keep the form body on the TS side: options.html and the jsdom tests share the same markup.
export const OPTIONS_BODY = `
  <h1>PrefabLens</h1>
  <p>
    <label>GitHub personal access token<br />
      <input id="pat" type="password" autocomplete="off" size="40" />
    </label>
  </p>
  <button id="save" type="button">Save</button>
  <span id="status" role="status"></span>
`;

type StorageLike = {
  get(keys: string[]): Promise<Record<string, unknown>>;
  set(items: Record<string, unknown>): Promise<void>;
};

export async function initOptions(doc: Document, storage: StorageLike): Promise<void> {
  const pat = doc.querySelector<HTMLInputElement>("#pat")!;
  const status = doc.querySelector<HTMLElement>("#status")!;

  const stored = await storage.get(["pat"]);
  pat.value = (stored.pat as string | undefined) ?? "";

  doc.querySelector<HTMLButtonElement>("#save")?.addEventListener("click", () => {
    void storage
      .set({ pat: pat.value.trim() })
      .then(() => {
        status.textContent = "Saved";
      })
      .catch(() => {
        status.textContent = "Save failed";
      });
  });
}

if (typeof chrome !== "undefined" && chrome.storage) {
  document.body.innerHTML = OPTIONS_BODY;
  void initOptions(document, chrome.storage.local);
}
