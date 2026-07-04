#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import { ensureCli, runCli } from './cli.js';
import { buildArgs, truncateTree } from './diff.js';

/** npm version = ダウンロードする CLI の Releases タグ(spec のバージョン規約)。 */
const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string };

const DESCRIPTION =
  'Semantic diff for Unity YAML assets (.prefab/.unity/.asset) between two git versions. ' +
  'Use this instead of reading raw YAML diffs: it matches objects by fileID and reports ' +
  'added/removed/modified GameObjects, components, fields, and prefab overrides with resolved names.';

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

serveStdio(() => {
  const server = new McpServer({ name: 'prefablens', version: pkg.version });

  server.registerTool(
    'prefab_diff',
    {
      description: DESCRIPTION,
      inputSchema: z.object({
        path: z.string().describe('Asset path (.prefab/.unity/.asset), relative to projectRoot'),
        before: z.string().default('HEAD').describe('Base git ref'),
        after: z.string().optional().describe('Target git ref; omit to compare against the working tree'),
        projectRoot: z.string().optional().describe('Repository root; defaults to the server cwd'),
        format: z.enum(['tree', 'json']).default('tree').describe('tree = readable text, json = prefablens.diff.v2'),
      }),
    },
    async ({ path: assetPath, before, after, projectRoot, format }) => {
      try {
        const cli = await ensureCli(pkg.version).catch((e: unknown) => {
          throw new Error(
            `prefablens CLI unavailable: ${message(e)}\n` +
            'Place the binary manually and set PREFABLENS_CLI to its path.',
          );
        });
        const res = await runCli(cli, buildArgs({ path: assetPath, before, after, format }), projectRoot ?? process.cwd());
        if (res.code !== 0) {
          return {
            content: [{ type: 'text' as const, text: res.stderr.trim() || `prefablens exited with code ${res.code}` }],
            isError: true,
          };
        }
        const text = format === 'tree' ? truncateTree(res.stdout) : res.stdout;
        return { content: [{ type: 'text' as const, text }] };
      } catch (e) {
        return { content: [{ type: 'text' as const, text: message(e) }], isError: true };
      }
    },
  );

  return server;
});
