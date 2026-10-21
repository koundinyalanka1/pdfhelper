# doc_common: notes for Claude Code sessions

The guide for these crates lives in `AGENTS.md`, so every coding agent
reads the same rules.

@AGENTS.md

## Claude Code only

- **The file-writing tool decodes `\uXXXX` escapes** in file content. To
  put a literal backslash-u sequence in Rust source (escapes in `doc_xml`
  or `doc_encoding` tests), build it with `concat!` or an escaped string.
