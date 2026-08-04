import type { DifferGateway } from "./application/gateway/differ";
import type { MakeGithubClient } from "./application/gateway/github";
import type { GithubAuthGateway } from "./application/gateway/github-auth";
import type { MessengerGateway } from "./application/gateway/messenger";
import type { TokenRepository } from "./domain/auth/token-repository";
import type { DiffRepository } from "./domain/diff/diff-repository";
import type { GuidRepository } from "./domain/guid/guid-repository";
import type { RepoIndexRepository } from "./domain/guid/repo-index-repository";
import { createChromeDiffClient } from "./infrastructure/clients/chrome-diff-client";
import { createChromeGuidClient } from "./infrastructure/clients/chrome-guid-client";
import { createChromeMessenger } from "./infrastructure/clients/chrome-messenger-client";
import { createChromeRepoIndexClient } from "./infrastructure/clients/chrome-repo-index-client";
import { createChromeTokenClient } from "./infrastructure/clients/chrome-token-client";
import { createQueue } from "./infrastructure/clients/fetch-queue-client";
import {
  createFixtureFetchBytes,
  createFixtureSourceFetch,
  loadFixtureGuidIndex,
} from "./infrastructure/clients/fixture-client";
import { createQueuedFetch, GithubClient } from "./infrastructure/clients/github-client";
import { pollForToken, requestDeviceCode } from "./infrastructure/clients/github-device-flow-client";
import {
  createDiffer,
  createDifferLoader as createWasmDifferLoader,
} from "./infrastructure/clients/wasm-differ-client";

export function createTokenStore(): TokenRepository {
  return createChromeTokenClient(chrome.storage.local);
}

export function createMessenger(): MessengerGateway {
  return createChromeMessenger();
}

export function createDiffStore(): DiffRepository {
  return createChromeDiffClient(chrome.storage.session);
}

export function createGuidCache(): GuidRepository {
  return createChromeGuidClient(chrome.storage.local);
}

export function createRepoIndexStore(): RepoIndexRepository {
  return createChromeRepoIndexClient(chrome.storage.local);
}

export function createGithubAuth(): GithubAuthGateway {
  return { requestDeviceCode, pollForToken };
}

// One shared queue per factory: the user lane has priority over the prefetch traffic.
export function createClientFactory(concurrency: number): MakeGithubClient {
  const queue = createQueue(concurrency);
  return (base, token, lane) => new GithubClient(base, token, createQueuedFetch(queue, lane === "user"));
}

export function createDifferLoader(): () => Promise<DifferGateway> {
  return createWasmDifferLoader(chrome.runtime.getURL("prefablens.wasm"));
}

export async function createDemoDiffer(): Promise<DifferGateway> {
  return createDiffer(await createDemoFetchBytes()("prefablens.wasm"));
}

export function createFixtureGuidIndexLoader(): () => Promise<Map<string, string>> {
  return loadFixtureGuidIndex;
}

export function createDemoFetchBytes(): (url: string) => Promise<Uint8Array<ArrayBuffer>> {
  return createFixtureFetchBytes();
}

export function createDemoFetchSource(): (side: "before" | "after", path: string) => Promise<Uint8Array> {
  return createFixtureSourceFetch(createFixtureFetchBytes());
}
