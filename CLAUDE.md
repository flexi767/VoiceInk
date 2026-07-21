# VoiceInk repository guidance

## Code graph workflow

`code-review-graph` is configured through `.mcp.json`; its local
`.code-review-graph/` index is intentionally ignored. Check graph status before
broad searches, use semantic and impact queries before editing, and run change
detection after changes. Fall back to `rg` when graph output is incomplete.
