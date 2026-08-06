import type { PendingSignIn } from "../../domain/auth/token";

export const DEVICE_CODE_BOX_SELECTOR = "input.js-user-code-field";
// GitHub user codes are eight characters without the hyphen (ABCD-1234).
export const DEVICE_CODE_CHAR_COUNT = 8;

// Autofill DEVICE_CODE_BOX_SELECTOR on github.com/login/device.
// Markup contract: e2e/fixtures/device-activation.html (re-capture when autofill fails in production).
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): void {
  if (now > pending.expiresAt) return;
  const boxes = [...doc.querySelectorAll<HTMLInputElement>(DEVICE_CODE_BOX_SELECTOR)];
  const chars = pending.userCode.replace(/-/g, "");
  if (boxes.length !== chars.length || boxes.some((box) => box.value)) return;
  boxes.forEach((box, i) => {
    box.value = chars.charAt(i);
    // Keep GitHub's per-box auto-advance JS in sync with the programmatic fill
    box.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
