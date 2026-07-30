import type { GithubClient } from "../../infrastructure/providers/github-client";

// Method set = today's ClientLike on handler.ts
export type GithubPort = Pick<
  GithubClient,
  | "getPrRefs"
  | "listPrFiles"
  | "getCommit"
  | "compareRefs"
  | "resolveRefSha"
  | "getFileAtRef"
  | "getBlobRaw"
  | "listBlobShas"
  | "searchMetaByGuid"
  | "listMetaTree"
  | "batchBlobTexts"
>;
