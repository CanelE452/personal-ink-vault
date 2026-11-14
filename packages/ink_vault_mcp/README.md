# Personal Ink Vault MCP server

Local stdio MCP transport for the running Personal Ink Vault application. The
server never opens or writes a vault directly. Configure the application bridge
using `--bridge-file <path>` or `INK_VAULT_MCP_BRIDGE`.

SDK: official [`rmcp` 3.8.0](https://crates.io/crates/rmcp/3.8.0), released
2026-10-26. Exact published crate checksum is recorded in Cargo.lock. Official
release source: [`cd88056ffdc97756fbd98e5a12bbeb41758f0ce8`](https://github.com/modelcontextprotocol/rust-sdk/tree/cd88056ffdc97756fbd98e5a12bbeb41758f0ce8),
tag `rmcp-v3.8.0` (annotated tag object
`ecafcf8e08a8cdde83ba9ebaba7512c75f85fb9d`). Protocol version negotiation and
stdio framing belong to the SDK; no custom MCP negotiation is implemented.

Application setup: [MCP setup](../../docs/mcp-setup.md).

`office_edit` exposes 29 closed operation variants through the existing 16
tools. Word picture mutations use separate `wordImageAdd`, `wordImageMove`, and
`wordImageDelete` operations. PPT `imageAdd` keeps its slide ID and x/y geometry;
existing `imageReplace` keeps its image ID and sealed asset ID.

Presentation table text has a separate source-byte operation,
`presentationCellTextPatch`. Use only a normal slide table whose
`sourceTextPatchAuthority` has kind `sourceTextPatch` / version 1 and whose
cell `sourceTextPatch.canReplace` is true with `truncated:false`. The
source proof is independent of native `capabilities.canEditText`,
`textDetails`, and the full native `tableSha256`; an unknown native
fingerprint stays null. A RAW-only native truncation can coexist with a complete
source proof. Missing, hidden, partial, covered, master, or unsupported source
targets do not gain source permission.

The flat request fields are `authorityVersion:1`, `ownerId`, `tableId`,
`cellId`, `expectedSourceSha256`, `sourcePart`, `shapeId`,
`expectedSourceFrameSha256`, `expectedTextSha256`, `startUtf16`,
`endUtf16`, and `text`. Copy the original decimal `shapeId` exactly,
including leading zeroes, and use the canonical relative package part returned
by the read. Package/frame guards stay pinned to the batch input; full current
text SHA and half-open UTF-16 ranges apply after preceding source operations.
Offsets and resulting cell text are bounded to 131072 UTF-16 units. Empty
replacement is valid; XML1.0-invalid scalars and surrogate splits are rejected.
The application checks actual source/owner/table/cell references and fresh edit
authority before changing bytes.

Source patches require a source-only batch of at most 100 operations; existing
native operation batches keep their 128-operation bound. Shared insertion
boundaries use the first legal editable source fragment in source order, and a
replacement spanning runs keeps the first selected run's style. Protected
fields, hyperlinks, structural breaks and unsupported XML remain closed.
Source metadata has its own exact 1MiB JSON UTF-8 / 32768-node output budget,
including object-key nodes and repeated output positions. Lost source proof is
omitted/null or explicitly truncated and cannot authorize a replacement.

Keep using the existing `office_edit.expectedRevisionId`, write permission,
preview/save path and request receipt. No new tool or receipt version is added.
Reuse a request ID only for the exact same complete operation JSON, including
every source/frame/text guard. Schema availability does not replace the app's
explicit source capability, clean reopen/PDF checks or immutable publication.

Read the current source revision and explicit `wordImageTargets` /
`wordImages.canMove` / `wordImages.canDelete` capabilities before editing. An
absent catalog is unknown; a verified empty image list can still have add
targets. The initial mutation scope is verified body AS_CHARACTER pictures.
Unknown capabilities and unsupported owners or protected points stay disabled.

Add takes a new batch `id`, `ownerId`, `paragraphId`, `offsetUtf16`, the full
current paragraph's `expectedTextSha256`, a sealed `assetId`, and `width` /
`height` in millimetres. Move takes the same target fields and an existing
source-or-batch image `id`, preserving picture properties without an asset or
dimensions. Delete takes only that exact `id`. A deleted alias cannot be reused
within the batch; use fresh IDs returned by `read_document` after saving.

The offset is an unsigned 32-bit integer with a discoverable maximum of
20,000,000 UTF-16 units. The application validates its current text boundary and
protected ranges. New Word dimensions must be positive, at most 1000mm, and
have at most two decimal places. PNG/JPEG uploads retain the existing 20MiB /
40-million-pixel limit and 80MiB edit batch limit. Assets are bound to the note
and source revision through `office_asset` begin/append/seal; no host path or
URL is accepted. The local app remains responsible for capability, source
revision, write permission, native verification, and immutable publication.

`generate_licenses.py` adapts the project's existing checksum-verifying notice
generator without changing the shared generator. It covers every locked package,
including test and target-specific dependencies. Unicode V3 and matchit's combined
MIT/BSD terms are checked against the actual cached package notice texts. Run
`python packages/ink_vault_mcp/generate_licenses.py --check` with the same cargo
cache to reproduce the committed notice bundle. `LICENSE` contains the application
GPL v3 text; `THIRD_PARTY_LICENSES.txt` contains dependency notices in full.
