import { describe, expect, it, vi } from "vitest";
import { applyGhes, ghesOrigins } from "./ghes";

function fakeChrome(granted = true) {
  return {
    permissions: { request: vi.fn(async () => granted) },
    scripting: {
      registerContentScripts: vi.fn(async () => {}),
      unregisterContentScripts: vi.fn(async () => {}),
    },
  };
}

describe("ghesOrigins", () => {
  it("returns null for github.com and empty", () => {
    expect(ghesOrigins("")).toBeNull();
    expect(ghesOrigins("github.com")).toBeNull();
    expect(ghesOrigins("https://github.com")).toBeNull();
  });

  it("builds a port-less match pattern", () => {
    expect(ghesOrigins("ghe.corp.com")).toEqual(["https://ghe.corp.com/*"]);
    expect(ghesOrigins("https://ghe.corp.com/")).toEqual(["https://ghe.corp.com/*"]);
    expect(ghesOrigins("http://127.0.0.1:8080")).toEqual(["http://127.0.0.1/*"]);
  });
});

describe("applyGhes", () => {
  it("unregisters stale registration then registers the GHES origin", async () => {
    const c = fakeChrome();
    expect(await applyGhes("ghe.corp.com", c)).toBe("ok");
    expect(c.scripting.unregisterContentScripts).toHaveBeenCalledWith({ ids: ["prefablens-ghes"] });
    expect(c.permissions.request).toHaveBeenCalledWith({ origins: ["https://ghe.corp.com/*"] });
    expect(c.scripting.registerContentScripts).toHaveBeenCalledWith([
      { id: "prefablens-ghes", matches: ["https://ghe.corp.com/*"], js: ["content.js"], runAt: "document_idle" },
    ]);
  });

  it("only clears registration for github.com", async () => {
    const c = fakeChrome();
    expect(await applyGhes("", c)).toBe("ok");
    expect(c.scripting.unregisterContentScripts).toHaveBeenCalledWith({ ids: ["prefablens-ghes"] });
    expect(c.permissions.request).not.toHaveBeenCalled();
    expect(c.scripting.registerContentScripts).not.toHaveBeenCalled();
  });

  it("returns declined without registering when permission is denied", async () => {
    const c = fakeChrome(false);
    expect(await applyGhes("ghe.corp.com", c)).toBe("declined");
    expect(c.scripting.registerContentScripts).not.toHaveBeenCalled();
    // Even on denial, clean up stale registration for an old GHES
    expect(c.scripting.unregisterContentScripts).toHaveBeenCalledWith({ ids: ["prefablens-ghes"] });
  });

  it("requests permission before any other async chrome call (user gesture)", async () => {
    const calls: string[] = [];
    const c = fakeChrome();
    c.permissions.request.mockImplementation(async () => {
      calls.push("request");
      return true;
    });
    c.scripting.unregisterContentScripts.mockImplementation(async () => {
      calls.push("unregister");
    });
    await applyGhes("ghe.corp.com", c);
    expect(calls[0]).toBe("request");
  });

  it("survives unregister rejection (no stale registration)", async () => {
    const c = fakeChrome();
    c.scripting.unregisterContentScripts.mockRejectedValue(new Error("no such id"));
    expect(await applyGhes("ghe.corp.com", c)).toBe("ok");
    expect(c.scripting.registerContentScripts).toHaveBeenCalledTimes(1);
  });
});
