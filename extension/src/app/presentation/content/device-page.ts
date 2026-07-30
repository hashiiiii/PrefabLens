import type { PendingSignIn } from "../../application/auth/sign-in";

// Autofill Device Activation boxes (js-user-code-field). Markup drift → no-op; user pastes instead.
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): boolean {
  if (now > pending.expiresAt) return false;
  const boxes = [...doc.querySelectorAll<HTMLInputElement>("input.js-user-code-field")];
  const chars = pending.userCode.replace(/-/g, "");
  if (boxes.length !== chars.length || boxes.some((box) => box.value)) return false;
  boxes.forEach((box, i) => {
    box.value = chars.charAt(i);
    // Keep GitHub's per-box auto-advance JS in sync with the programmatic fill
    box.dispatchEvent(new Event("input", { bubbles: true }));
  });
  return true;
}
