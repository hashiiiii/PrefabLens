// @vitest-environment jsdom
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { must } from "../../internal/must";
import { DEVICE_CODE_BOX_SELECTOR, DEVICE_CODE_CHAR_COUNT, fillDeviceCode } from "./device-page";

const PENDING = { userCode: "ABCD-1234", expiresAt: 10_000 };
const fixture = readFileSync(join(process.cwd(), "e2e/fixtures/device-activation.html"), "utf8");

function loadFixture(doc: Document): void {
  doc.body.innerHTML = new DOMParser().parseFromString(fixture, "text/html").body.innerHTML;
}

function boxes(doc: Document): HTMLInputElement[] {
  return [...doc.querySelectorAll<HTMLInputElement>(DEVICE_CODE_BOX_SELECTOR)];
}

describe("fillDeviceCode", () => {
  it("fixture matches the autofill contract", () => {
    loadFixture(document);
    expect(boxes(document).length).toBe(DEVICE_CODE_CHAR_COUNT);
  });

  it.each([
    { name: "expired pending", now: 10_001, setup: () => loadFixture(document) },
    {
      name: "box count mismatch",
      now: 5_000,
      setup: () => {
        loadFixture(document);
        must(boxes(document)[7]).remove();
      },
    },
  ])("no-ops when $name", ({ now, setup }) => {
    setup();
    fillDeviceCode(document, PENDING, now);
    expect(boxes(document).every((b) => b.value === "")).toBe(true);
  });

  it("does not clobber a box the user already typed into", () => {
    loadFixture(document);
    must(boxes(document)[2]).value = "X";
    fillDeviceCode(document, PENDING, 5_000);
    expect(must(boxes(document)[0]).value).toBe("");
    expect(must(boxes(document)[2]).value).toBe("X");
  });

  it("no-ops when the boxes are absent", () => {
    document.body.innerHTML = "<form><input type='text' name='something-else'></form>";
    fillDeviceCode(document, PENDING, 5_000);
    expect(must(document.querySelector<HTMLInputElement>("input[name='something-else']")).value).toBe("");
  });
});
