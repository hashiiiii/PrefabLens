import type { PendingSignIn } from "./signin";

/** Best-effort autofill of GitHub's device-verification form. The live page renders one
 *  single-character box per code character (the hyphen is a visual separator, not a box);
 *  older/simpler layouts use one combined input. Anything else silently no-ops and the
 *  user pastes the code from the PR page instead. */
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): boolean {
  if (now > pending.expiresAt) return false;
  const inputs = [...doc.querySelectorAll<HTMLInputElement>('form input[type="text"]:not([hidden])')];
  if (!inputs.length || inputs.some((input) => input.value)) return false;
  const chars = pending.userCode.replace(/-/g, "");
  const values = inputs.length === 1 ? [pending.userCode] : inputs.length === chars.length ? [...chars] : null;
  if (!values) return false;
  inputs.forEach((input, i) => {
    input.value = values[i]!;
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  return true;
}
