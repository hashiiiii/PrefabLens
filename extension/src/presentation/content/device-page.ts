import type { PendingSignIn } from "../../domain/auth/pending-sign-in";

// If the form structure changes, this function does nothing and the user can enter the code manually.
export function fillDeviceCode(doc: Document, pending: PendingSignIn, now: number): void {
  if (now > pending.expiresAt) return;
  const boxes = [...doc.querySelectorAll<HTMLInputElement>("input.js-user-code-field")];
  const chars = pending.userCode.replace(/-/g, "");
  if (boxes.length !== chars.length || boxes.some((box) => box.value)) return;
  boxes.forEach((box, i) => {
    box.value = chars.charAt(i);
    // This event tells GitHub that the box value changed. Then GitHub advances to the next box.
    box.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
