import type { PendingSignIn } from "./signin";

/** Autofill of GitHub's Device Activation form. The eight fillable boxes are marked with
 *  GitHub's js-user-code-field hook class (a ninth user-code input is a CSS-hidden readonly
 *  hyphen placeholder and must be ignored). If GitHub redesigns the form this no-ops and
 *  the user pastes the code shown on the PR page instead. */
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): boolean {
  if (now > pending.expiresAt) return false;
  const boxes = [...doc.querySelectorAll<HTMLInputElement>("input.js-user-code-field")];
  const chars = pending.userCode.replace(/-/g, "");
  if (boxes.length !== chars.length || boxes.some((box) => box.value)) return false;
  boxes.forEach((box, i) => {
    box.value = chars[i]!;
    // GitHub's auto-advance JS listens per box; keep it in sync with the programmatic fill.
    box.dispatchEvent(new Event("input", { bubbles: true }));
  });
  return true;
}
