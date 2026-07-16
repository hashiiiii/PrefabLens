// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { must } from "../util/must";
import { fillDeviceCode } from "./devicePage";

const PENDING = { userCode: "ABCD-1234", expiresAt: 10_000 };

// Trimmed copy of the real Device Activation form (captured 2026-07-11): eight fillable
// boxes marked js-user-code-field plus a ninth CSS-hidden readonly input holding the hyphen.
function box(n: number): string {
  return `<input type="text" name="user-code-${n}" id="user-code-${n}" class="form-control js-user-code-field h1" maxlength="1" aria-label="User code ${n}">`;
}
const FORM =
  '<form action="/login/device/confirmation" method="post">' +
  '<input type="hidden" name="authenticity_token" value="tok">' +
  box(0) +
  box(1) +
  box(2) +
  box(3) +
  '<input type="text" name="user-code-4" id="user-code-4" class="d-none" aria-label="User code 4" value="-" readonly="">' +
  box(5) +
  box(6) +
  box(7) +
  box(8) +
  '<input type="submit" name="commit" value="Continue">' +
  "</form>";

function boxes(): HTMLInputElement[] {
  return [...document.querySelectorAll<HTMLInputElement>("input.js-user-code-field")];
}

describe("fillDeviceCode", () => {
  it("fills the eight code boxes in order, skipping the hyphen, and fires input on each", () => {
    document.body.innerHTML = FORM;
    // GitHub enhances the boxes with JS (auto-advance via data-next); input events keep it in sync.
    let fired = 0;
    for (const b of boxes()) {
      b.addEventListener("input", () => {
        fired += 1;
      });
    }
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(true);
    expect(boxes().map((b) => b.value)).toEqual(["A", "B", "C", "D", "1", "2", "3", "4"]);
    expect(fired).toBe(8);
  });

  it("leaves the readonly hyphen placeholder and the csrf token untouched", () => {
    document.body.innerHTML = FORM;
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(true);
    // The hyphen input carries value "-" from the server; it must neither block the fill nor be overwritten.
    expect(must(document.querySelector<HTMLInputElement>('input[name="user-code-4"]')).value).toBe("-");
    expect(must(document.querySelector<HTMLInputElement>('input[name="authenticity_token"]')).value).toBe("tok");
  });

  it("does not touch anything once the pending code expired", () => {
    document.body.innerHTML = FORM;
    expect(fillDeviceCode(document, PENDING, 10_001)).toBe(false);
    expect(boxes().every((b) => b.value === "")).toBe(true);
  });

  it("does not clobber a box the user already typed into", () => {
    document.body.innerHTML = FORM;
    must(boxes()[2]).value = "X";
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
    expect(must(boxes()[0]).value).toBe("");
    expect(must(boxes()[2]).value).toBe("X");
  });

  it("no-ops when the box count does not match the code length (unknown layout)", () => {
    document.body.innerHTML = FORM;
    must(boxes()[7]).remove();
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
    expect(boxes().every((b) => b.value === "")).toBe(true);
  });

  it("no-ops when the boxes are absent (redesigned page)", () => {
    document.body.innerHTML = "<form><input type='text' name='something-else'></form>";
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
  });
});
