// GitHub instance model: which API endpoints and permissions a page origin implies.
// github.com and plain Enterprise Cloud live on github.com; data-residency Enterprise
// Cloud is `<sub>.ghe.com` with the API on an `api.` subdomain; anything else is treated
// as GHES, which serves REST under /api/v3 and GraphQL under /api/graphql on the same origin.

export const GITHUB_ORIGIN = "https://github.com";

export type HostApi = {
  restBase: string;
  graphqlUrl: string;
  // Calendar-versioned API (x-github-api-version): github.com and ghe.com accept 2022-11-28;
  // GHES accepts only its own release's date, so the header is omitted there.
  versioned: boolean;
};

// origin → { pat }. github.com is absent by design: its token stays under the legacy `pat` key.
export type Instances = Record<string, { pat?: string }>;

export function resolveApi(origin: string): HostApi {
  if (origin === GITHUB_ORIGIN) {
    return { restBase: "https://api.github.com", graphqlUrl: "https://api.github.com/graphql", versioned: true };
  }
  const host = new URL(origin).host;
  if (host.endsWith(".ghe.com")) {
    return { restBase: `https://api.${host}`, graphqlUrl: `https://api.${host}/graphql`, versioned: true };
  }
  return { restBase: `${origin}/api/v3`, graphqlUrl: `${origin}/api/graphql`, versioned: false };
}

/** Host permission patterns an instance needs: the page origin, plus the API origin when it differs. */
export function permissionPatterns(origin: string): string[] {
  const patterns = [`${origin}/*`];
  const host = new URL(origin).host;
  if (host.endsWith(".ghe.com")) patterns.push(`https://api.${host}/*`);
  return patterns;
}

// Dynamic content-script registrations are namespaced so sync never touches foreign IDs.
export const SCRIPT_PREFIX = "prefablens-instance:";

export function scriptId(origin: string): string {
  return `${SCRIPT_PREFIX}${origin}`;
}

/** Diffs current registrations against permission-granted instances (registrations are
 *  cleared on extension update, and permissions can be revoked from chrome://extensions). */
export function scriptSyncPlan(registeredIds: string[], grantedOrigins: string[]): { add: string[]; remove: string[] } {
  const want = new Set(grantedOrigins.map(scriptId));
  const have = new Set(registeredIds);
  return {
    add: grantedOrigins.filter((origin) => !have.has(scriptId(origin))),
    remove: registeredIds.filter((id) => id.startsWith(SCRIPT_PREFIX) && !want.has(id)),
  };
}
