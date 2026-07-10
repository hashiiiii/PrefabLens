import type { PendingSignIn } from "./signin";

/** Best-effort autofill of GitHub's device-verification form. The code input has no stable
 *  documented selector, so target the first visible text input inside a form; if GitHub's
 *  DOM changes this silently no-ops and the user pastes the code from the PR page instead. */
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): boolean {
  if (now > pending.expiresAt) return false;
  const input = doc.querySelector<HTMLInputElement>('form input[type="text"]:not([hidden])');
  if (!input || input.value) return false;
  input.value = pending.userCode;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  return true;
}
