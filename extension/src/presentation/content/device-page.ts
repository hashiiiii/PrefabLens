import type { PendingSignIn } from "../../domain/auth/token";

// Autofill input.js-user-code-field on github.com/login/device.
// Markup contract: e2e/fixtures/device-activation.html
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): void {
  if (now > pending.expiresAt) return;
  const boxes = [...doc.querySelectorAll<HTMLInputElement>("input.js-user-code-field")];
  const chars = pending.userCode.replace(/-/g, "");
  if (boxes.length !== chars.length || boxes.some((box) => box.value)) return;
  boxes.forEach((box, i) => {
    box.value = chars.charAt(i);
    // Keep GitHub's per-box auto-advance JS in sync with the programmatic fill
    box.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
