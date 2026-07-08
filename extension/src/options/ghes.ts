import { originOf } from "../github/client";

export type ChromeGhes = {
  permissions: { request(p: { origins: string[] }): Promise<boolean> };
  scripting: {
    registerContentScripts(scripts: object[]): Promise<void>;
    unregisterContentScripts(filter: { ids: string[] }): Promise<void>;
  };
};

const ID = "prefablens-ghes";

/** The content-script injection target when baseUrl points at GHES. A match pattern can't include a port (port-less matches all ports). */
export function ghesOrigins(baseUrl: string): string[] | null {
  if (!baseUrl) return null;
  const origin = originOf(baseUrl);
  if (origin === "https://github.com") return null;
  const u = new URL(origin);
  return [`${u.protocol}//${u.hostname}/*`];
}

/** Call inside the Save click (user gesture): permission request → dynamic content-script registration. Registration persists, so no startup handling is needed.
 *  Call permissions.request before any other await to avoid the gesture expiring. */
export async function applyGhes(baseUrl: string, c: ChromeGhes): Promise<"ok" | "declined"> {
  const origins = ghesOrigins(baseUrl); // an invalid URL throws here → the caller treats it as 'failed'
  const granted = !origins || (await c.permissions.request({ origins }));
  await c.scripting.unregisterContentScripts({ ids: [ID] }).catch(() => {}); // rejects if not registered
  if (!origins) return "ok";
  if (!granted) return "declined";
  await c.scripting.registerContentScripts([{ id: ID, matches: origins, js: ["content.js"], runAt: "document_idle" }]);
  return "ok";
}
