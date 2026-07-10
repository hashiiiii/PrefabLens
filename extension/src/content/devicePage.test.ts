// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { fillDeviceCode } from "./devicePage";

const PENDING = { userCode: "ABCD-1234", expiresAt: 10_000 };

// GitHub's real form (shape as of 2026-07) carries hidden honeypot text inputs
// next to the visible code input; the selector must skip them.
const FORM =
  '<form><input class="form-control" type="text" name="required_field_fdc0" hidden="hidden" />' +
  '<input type="text" name="user_code" /></form>';

// The live Device Activation page renders one single-character box per code character
// (eight boxes for XXXX-XXXX; the hyphen is a visual separator, not a box).
const SEGMENTED_FORM =
  '<form><input class="form-control" type="text" name="required_field_fdc0" hidden="hidden" />' +
  Array.from({ length: 8 }, (_, i) => `<input type="text" maxlength="1" name="seg${i}" />`).join("") +
  "</form>";

function segments(): HTMLInputElement[] {
  return [...document.querySelectorAll<HTMLInputElement>('input[name^="seg"]')];
}

describe("fillDeviceCode", () => {
  it("fills the visible text input and fires an input event", () => {
    document.body.innerHTML = FORM;
    const input = document.querySelector<HTMLInputElement>('input[name="user_code"]')!;
    // GitHub enhances the form with JS; dispatching input keeps its listeners in sync.
    let fired = false;
    input.addEventListener("input", () => {
      fired = true;
    });
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(true);
    expect(input.value).toBe("ABCD-1234");
    expect(fired).toBe(true);
    // The hidden honeypot must stay empty or GitHub rejects the submission.
    expect(document.querySelector<HTMLInputElement>('input[name="required_field_fdc0"]')!.value).toBe("");
  });

  it("does not touch anything once the pending code expired", () => {
    document.body.innerHTML = FORM;
    expect(fillDeviceCode(document, PENDING, 10_001)).toBe(false);
    expect(document.querySelector<HTMLInputElement>('input[name="user_code"]')!.value).toBe("");
  });

  it("does not clobber a code the user already typed", () => {
    document.body.innerHTML = FORM;
    const input = document.querySelector<HTMLInputElement>('input[name="user_code"]')!;
    input.value = "WXYZ-9876";
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
    expect(input.value).toBe("WXYZ-9876");
  });

  it("no-ops when the expected form is absent", () => {
    document.body.innerHTML = "<p>redesigned page</p>";
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
  });
});

describe("fillDeviceCode on the segmented layout", () => {
  it("distributes one character per box, skipping the hyphen, and fires input on each", () => {
    document.body.innerHTML = SEGMENTED_FORM;
    let fired = 0;
    for (const box of segments()) {
      box.addEventListener("input", () => {
        fired += 1;
      });
    }
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(true);
    expect(segments().map((box) => box.value)).toEqual(["A", "B", "C", "D", "1", "2", "3", "4"]);
    expect(fired).toBe(8);
    expect(document.querySelector<HTMLInputElement>('input[name="required_field_fdc0"]')!.value).toBe("");
  });

  it("no-ops when the box count does not match the code length (unknown layout)", () => {
    document.body.innerHTML = SEGMENTED_FORM;
    segments()[7]!.remove(); // 7 boxes for 8 characters: do not guess
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
    expect(segments().every((box) => box.value === "")).toBe(true);
  });

  it("does not clobber a box the user already typed into", () => {
    document.body.innerHTML = SEGMENTED_FORM;
    segments()[2]!.value = "X";
    expect(fillDeviceCode(document, PENDING, 5_000)).toBe(false);
    expect(segments()[0]!.value).toBe("");
    expect(segments()[2]!.value).toBe("X");
  });
});
