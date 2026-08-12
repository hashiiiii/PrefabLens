import type { DifferGateway } from "./application/gateway/differ";
import type { FixturesGateway } from "./application/gateway/fixtures";
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
import { createFixtureClient } from "./infrastructure/clients/fixture-client";
import { createGithubClientFactory } from "./infrastructure/clients/github-client";
import { createGithubDeviceFlowClient } from "./infrastructure/clients/github-device-flow-client";
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
  return createGithubDeviceFlowClient();
}

export function createClientFactory(concurrency: number): MakeGithubClient {
  return createGithubClientFactory(concurrency);
}

export function createDifferLoader(): () => Promise<DifferGateway> {
  return createWasmDifferLoader(chrome.runtime.getURL("prefablens.wasm"));
}

export async function createDemoDiffer(): Promise<DifferGateway> {
  return createDiffer(await createFixtureClient().fetchBytes("prefablens.wasm"));
}

export function createFixtures(): FixturesGateway {
  return createFixtureClient();
}
