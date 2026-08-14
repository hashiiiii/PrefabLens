import type { DifferGateway } from "./application/gateway/differ";
import type { FixturesGateway } from "./application/gateway/fixtures";
import type { MakeGithubGateway } from "./application/gateway/github";
import type { GithubAuthGateway } from "./application/gateway/github-auth";
import type { MessengerGateway } from "./application/gateway/messenger";
import type { AuthRepository } from "./domain/auth/auth-repository";
import type { DiffRepository } from "./domain/diff/diff-repository";
import type { GuidRepository } from "./domain/guid/guid-repository";
import type { RepoIndexRepository } from "./domain/guid/repo-index-repository";
import { createChromeAuthRepository } from "./infrastructure/clients/chrome-auth-client";
import { createChromeDiffRepository } from "./infrastructure/clients/chrome-diff-client";
import { createChromeGuidRepository } from "./infrastructure/clients/chrome-guid-client";
import { createChromeMessengerGateway } from "./infrastructure/clients/chrome-messenger-client";
import { createChromeRepoIndexRepository } from "./infrastructure/clients/chrome-repo-index-client";
import { createFixturesGateway as createHttpFixturesGateway } from "./infrastructure/clients/fixture-client";
import { createGithubGateway as createQueuedGithubGateway } from "./infrastructure/clients/github-client";
import { createGithubDeviceFlowGateway } from "./infrastructure/clients/github-device-flow-client";
import { createDifferGateway as createWasmDifferGateway } from "./infrastructure/clients/wasm-differ-client";

export function createAuthRepository(): AuthRepository {
  return createChromeAuthRepository(chrome.storage.local);
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
