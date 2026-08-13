import type { DifferGateway } from "./application/gateway/differ";
import type { FixturesGateway } from "./application/gateway/fixtures";
import type { MakeGithubGateway } from "./application/gateway/github";
import type { GithubAuthGateway } from "./application/gateway/github-auth";
import type { MessengerGateway } from "./application/gateway/messenger";
import type { TokenRepository } from "./domain/auth/token-repository";
import type { DiffRepository } from "./domain/diff/diff-repository";
import type { GuidRepository } from "./domain/guid/guid-repository";
import type { RepoIndexRepository } from "./domain/guid/repo-index-repository";
import { createChromeDiffRepository } from "./infrastructure/clients/chrome-diff-client";
import { createChromeGuidRepository } from "./infrastructure/clients/chrome-guid-client";
import { createChromeMessengerGateway } from "./infrastructure/clients/chrome-messenger-client";
import { createChromeRepoIndexRepository } from "./infrastructure/clients/chrome-repo-index-client";
import { createChromeTokenRepository } from "./infrastructure/clients/chrome-token-client";
import { createFixturesGateway as createHttpFixturesGateway } from "./infrastructure/clients/fixture-client";
import { createGithubGateway as createQueuedGithubGateway } from "./infrastructure/clients/github-client";
import { createGithubDeviceFlowGateway } from "./infrastructure/clients/github-device-flow-client";
import { createDifferGateway as createWasmDifferGateway } from "./infrastructure/clients/wasm-differ-client";

export function createTokenRepository(): TokenRepository {
  return createChromeTokenRepository(chrome.storage.local);
}

export function createMessengerGateway(): MessengerGateway {
  return createChromeMessengerGateway();
}

export function createDiffRepository(): DiffRepository {
  return createChromeDiffRepository(chrome.storage.session);
}

export function createGuidRepository(): GuidRepository {
  return createChromeGuidRepository(chrome.storage.local);
}

export function createRepoIndexRepository(): RepoIndexRepository {
  return createChromeRepoIndexRepository(chrome.storage.local);
}

export function createGithubAuthGateway(): GithubAuthGateway {
  return createGithubDeviceFlowGateway();
}

export function createGithubGateway(concurrency: number): MakeGithubGateway {
  return createQueuedGithubGateway(concurrency);
}

export function createDifferGateway(): () => Promise<DifferGateway> {
  return createWasmDifferGateway(chrome.runtime.getURL("prefablens.wasm"));
}

export function createDemoDifferGateway(fetchBytes: FixturesGateway["fetchBytes"]): () => Promise<DifferGateway> {
  return createWasmDifferGateway("prefablens.wasm", fetchBytes);
}

export function createFixturesGateway(): FixturesGateway {
  return createHttpFixturesGateway();
}
