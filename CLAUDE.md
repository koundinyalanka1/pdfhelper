# DocHelper: notes for Claude Code sessions

The guide for this repository lives in `AGENTS.md`, so every coding agent
reads the same rules. Keep the guide there; this file imports it and adds
notes for Claude Code alone.

@AGENTS.md

## Claude Code only

- **The file-writing tool decodes `\uXXXX` escapes** in file content. To
  put a literal backslash-u sequence in source, build it with `concat!` or
  an escaped string.
