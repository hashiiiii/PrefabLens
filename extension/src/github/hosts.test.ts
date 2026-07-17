import { describe, expect, it } from "vitest";
import { GITHUB_ORIGIN, permissionPatterns, resolveApi, scriptId, scriptSyncPlan } from "./hosts";

describe("resolveApi", () => {
  it("maps github.com to the api.github.com pair with the version header", () => {
    expect(resolveApi(GITHUB_ORIGIN)).toEqual({
      restBase: "https://api.github.com",
      graphqlUrl: "https://api.github.com/graphql",
      versioned: true,
    });
  });

  it("maps a ghe.com data-residency origin to its api subdomain", () => {
    // Enterprise Cloud data residency: web at <sub>.ghe.com, API at api.<sub>.ghe.com
    expect(resolveApi("https://acme.ghe.com")).toEqual({
      restBase: "https://api.acme.ghe.com",
      graphqlUrl: "https://api.acme.ghe.com/graphql",
      versioned: true,
    });
  });

  it("maps a GHES origin to /api/v3 and /api/graphql without the version header", () => {
    // GHES serves GraphQL at /api/graphql, NOT /api/v3/graphql — the pair cannot be derived
    // from the REST base. The version header is omitted: GHES only accepts its own date value.
    expect(resolveApi("https://github.example.com")).toEqual({
      restBase: "https://github.example.com/api/v3",
      graphqlUrl: "https://github.example.com/api/graphql",
      versioned: false,
    });
  });

  it("keeps the origin's scheme and port for GHES (e2e loopback)", () => {
    expect(resolveApi("http://127.0.0.1:8471").restBase).toBe("http://127.0.0.1:8471/api/v3");
  });
});

describe("permissionPatterns", () => {
  it("needs only the instance origin for GHES (API is same-origin)", () => {
    expect(permissionPatterns("https://github.example.com")).toEqual(["https://github.example.com/*"]);
  });

  it("adds the api subdomain for ghe.com (API is cross-origin)", () => {
    expect(permissionPatterns("https://acme.ghe.com")).toEqual([
      "https://acme.ghe.com/*",
      "https://api.acme.ghe.com/*",
    ]);
  });
});

describe("scriptSyncPlan", () => {
  it("registers granted origins that are missing and drops registrations without a backing instance", () => {
    // "some-other-extension-script" lacks the prefablens prefix: sync must never touch foreign IDs
    const plan = scriptSyncPlan(
      [scriptId("https://old.example.com"), "some-other-extension-script"],
      ["https://new.example.com"],
    );
    expect(plan).toEqual({ add: ["https://new.example.com"], remove: [scriptId("https://old.example.com")] });
  });

  it("is a no-op when registrations already match", () => {
    expect(scriptSyncPlan([scriptId("https://a.example.com")], ["https://a.example.com"])).toEqual({
      add: [],
      remove: [],
    });
  });
});
