// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { must } from "../../../src/internal/must";
import { fillDeviceCode } from "../../../src/presentation/content/device-page";

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
  it("fills the eight code boxes and omits the hyphen", () => {
    document.body.innerHTML = FORM;
    fillDeviceCode(document, { userCode: "ABCD-1234", expiresAt: 10_000 }, 5_000);

    expect(boxes().map((box) => box.value)).toEqual(["A", "B", "C", "D", "1", "2", "3", "4"]);
  });

  it("dispatches one input event for each filled box", () => {
    document.body.innerHTML = FORM;
    let fired = 0;
    // GitHub uses input events to advance to the next box.
    must(document.querySelector("form")).addEventListener("input", () => {
      fired += 1;
    });

    fillDeviceCode(document, { userCode: "ABCD-1234", expiresAt: 10_000 }, 5_000);

    expect(fired).toBe(8);
  });

  it("does not change the form when the pending code expired", () => {
    document.body.innerHTML = FORM;
    fillDeviceCode(document, { userCode: "ABCD-1234", expiresAt: 10_000 }, 10_001);

    expect(boxes().map((box) => box.value)).toStrictEqual(["", "", "", "", "", "", "", ""]);
  });

  it("does not fill any box when one box has a value", () => {
    document.body.innerHTML = FORM;
    must(boxes()[2]).value = "X";
    fillDeviceCode(document, { userCode: "ABCD-1234", expiresAt: 10_000 }, 5_000);

    expect(boxes().map((box) => box.value)).toEqual(["", "", "X", "", "", "", "", ""]);
  });

  it("does not fill boxes when their count differs from the code length", () => {
    document.body.innerHTML = FORM;
    must(boxes()[7]).remove();
    fillDeviceCode(document, { userCode: "ABCD-1234", expiresAt: 10_000 }, 5_000);

    expect(boxes().map((box) => box.value)).toEqual(["", "", "", "", "", "", ""]);
  });
});
