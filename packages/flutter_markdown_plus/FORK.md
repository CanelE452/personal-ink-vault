# Local Markdown block wrapper

This is the pinned `flutter_markdown_plus` 1.0.12 source, under its original
BSD-3-Clause license. LICENSE and AUTHORS are retained. The exact upstream file
hashes and the original hosted archive hash from the application lockfile are
recorded in UPSTREAM_PROVENANCE.json. The hosted archive was not independently
downloaded; these files were copied from the installed package cache and compared
before modification.

The local change adds an optional `MarkdownBlockWrapper` callback to the default
builder and widget constructors. It wraps a completed block widget, including a
block nested inside a list or blockquote, while preserving the default rendering
and processing the document AST once. A callback change also refreshes the widget
render cache. The application uses this hook to attach scroll targets to actual
heading and paragraph widgets.
