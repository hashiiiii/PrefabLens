# @hashiiiii/prefablens-mcp

MCP server for [PrefabLens](https://github.com/hashiiiii/PrefabLens) — semantic diffs of Unity YAML assets (`.prefab` / `.unity` / `.asset`) between two git versions.

Instead of reading raw YAML diffs, agents get a tree of added/removed/modified GameObjects, components, fields, and prefab overrides, with fileID-based object matching and names resolved via `.meta` guid scanning.

## Setup

Requires Node.js >= 22 and `git` on PATH.

Claude Code:

```sh
claude mcp add prefablens -- npx -y @hashiiiii/prefablens-mcp
```

Generic MCP client config:

```json
{
  "mcpServers": {
    "prefablens": {
      "command": "npx",
      "args": ["-y", "@hashiiiii/prefablens-mcp"]
    }
  }
}
```

## Tool: `prefab_diff`

| Parameter | Default | Description |
|---|---|---|
| `path` | (required) | Asset path (`.prefab`/`.unity`/`.asset`), relative to `projectRoot` |
| `before` | `HEAD` | Base git ref |
| `after` | working tree | Target git ref; omit to compare against the working tree |
| `projectRoot` | server cwd | Repository root (also the base for `.meta` guid resolution) |
| `format` | `tree` | `tree` = readable text (truncated at 50k chars), `json` = `prefablens.diff.v2` |

Example call:

```json
{ "path": "Assets/Prefabs/Player.prefab", "before": "main", "projectRoot": "/path/to/unity-project" }
```

## How the CLI is obtained

The server drives the `prefablens` CLI as a subprocess. On first use it downloads the CLI matching this package's version from [GitHub Releases](https://github.com/hashiiiii/PrefabLens/releases) and caches it under `~/.cache/prefablens/<version>/`.

To use a pre-installed binary instead (offline or restricted environments), set `PREFABLENS_CLI` to its path in the server's environment.
