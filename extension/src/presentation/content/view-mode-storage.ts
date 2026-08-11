import type { View } from "../internal/view-mode";

// Storage requests can fail after an extension reload.
// The current page remains usable without the persisted view preference.
export async function loadViewMode(): Promise<View> {
  try {
    const stored = await chrome.storage.local.get(["viewMode"]);
    return stored.viewMode === "semantic" ? "semantic" : "raw";
  } catch {
    return "raw";
  }
}

export async function saveViewMode(view: View): Promise<void> {
  try {
    await chrome.storage.local.set({ viewMode: view });
  } catch {}
}
