# VoiceInk

## Code graph workflow

`code-review-graph` is installed for this repository. `.mcp.json` points to the
local MCP server (`scripts/code-review-graph-mcp.sh`) and `.code-review-graph/`
is intentionally ignored.

Use the graph before broad text searches or whole-file reads:

1. Check graph status and rebuild it if stale.
2. Use semantic search for symbols and concepts.
3. Use impact radius plus callers/callees/imports/tests queries before editing.
4. After changes, use change detection, review context, and affected flows.
5. Fall back to `rg` when graph output is incomplete or the question is textual.

If MCP tools are unavailable, use the installed CLI or
`uvx --from code-review-graph code-review-graph`.
