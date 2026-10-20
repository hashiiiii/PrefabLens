/// <reference types="node" />
import { createServer, type Server } from "node:http";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createGithubGateway } from "../../../src/infrastructure/clients/github-client";

describe("GitHub raw blob streaming limits", () => {
  let server: Server;
  let api: string;
  let sentBytes: number[];

  beforeEach(async () => {
    sentBytes = [];
    server = createServer(async (_request, response) => {
      const requestIndex = sentBytes.push(0) - 1;
      // Chunking keeps this a streaming transport test instead of testing an already-buffered Response body.
      for (let i = 0; i < 16 && !response.destroyed; i++) {
        const chunk = Buffer.alloc(4, i);
        response.write(chunk);
        sentBytes[requestIndex] = (sentBytes[requestIndex] ?? 0) + chunk.byteLength;
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
      if (!response.destroyed) response.end();
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    if (address === null || typeof address === "string") throw new Error("Expected a TCP server address");
    api = `http://127.0.0.1:${address.port}`;
  });

  afterEach(async () => {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  });

  it("cancels an oversized streaming body but allows the explicit unbounded retry", async () => {
    // GitHub blobs can be much larger than the render threshold, and PR prefetch reads them before the diff guard.
    // This uses native fetch and a real loopback HTTP stream so it verifies early cancellation at the transport boundary.
    const client = createGithubGateway(api, "test-token");

    const limited = await client.getBlobRaw("owner", "repo", "sha", 8);
    const forced = await client.getBlobRaw("owner", "repo", "sha", null);

    expect(limited).toEqual({ ok: false, error: { kind: "too-large", bytes: expect.any(Number), exact: false } });
    if (limited.ok || limited.error.kind !== "too-large") throw new Error("Expected a size limit error");
    expect(limited.error.bytes).toBeGreaterThan(8);
    expect(sentBytes[0]).toBeLessThan(64);
    expect(forced).toMatchObject({ ok: true, value: expect.any(Uint8Array) });
    if (!forced.ok || !forced.value) throw new Error("Expected the unbounded retry to return the complete blob");
    expect(forced.value.byteLength).toBe(64);
    expect(sentBytes[1]).toBe(64);
  });
});
