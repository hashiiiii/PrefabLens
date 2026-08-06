// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { must } from "../../internal/must";
import { fillDeviceCode } from "./device-page";

const PENDING = { userCode: "ABCD-1234", expiresAt: 10_000 };

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

function box(n: number): string {
  return `<input type="text" name="user-code-${n}" id="user-code-${n}" class="form-control js-user-code-field h1" maxlength="1" aria-label="User code ${n}">`;
}

function boxes(): HTMLInputElement[] {
  return [...document.querySelectorAll<HTMLInputElement>("input.js-user-code-field")];
}

describe("fillDeviceCode", () => {
  it("fills eight code boxes in order, skips the hyphen, and fires input on each box", () => {
    document.body.innerHTML = FORM;
    let fired = 0;
    for (const b of boxes()) {
      // GitHub adds JS to the boxes for auto-advance with data-next.
      // The input events keep the page in sync.
      b.addEventListener("input", () => {
        fired += 1;
      });
    }
    fillDeviceCode(document, PENDING, 5_000);
    expect(boxes().map((b) => b.value)).toEqual(["A", "B", "C", "D", "1", "2", "3", "4"]);
    expect(fired).toBe(8);
  });

  it("does not change the form when the pending code expired", () => {
    document.body.innerHTML = FORM;
    fillDeviceCode(document, PENDING, 10_001);
    expect(boxes().map(b => b.value)).toStrictEqual(["", "", "", "", "", "", "", ""]);
  });

  it("does not change a box that the user already filled", () => {
    document.body.innerHTML = FORM;
    must(boxes()[2]).value = "X";
    fillDeviceCode(document, PENDING, 5_000);
    expect(must(boxes()[0]).value).toBe("");
    expect(must(boxes()[2]).value).toBe("X");
  });

  it("does nothing when the box count does not match the code length", () => {
    document.body.innerHTML = FORM;
    must(boxes()[7]).remove();
    fillDeviceCode(document, PENDING, 5_000);
    expect(boxes().every((b) => b.value === "")).toBe(true);
  });
});
