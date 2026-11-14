# 페이지 글자 범위 서식 구현 계획

> For agentic workers: use superpowers:subagent-driven-development; root runs all tests and processes. Do not commit or publish.

**Goal:** 일반 페이지와 DB 행 본문에서 선택한 글자의 서식·링크를 편집하고 저장·이력·MCP·검색·내보내기까지 유지한다. 기존 Android/Windows/Drive·필기·Office·Obsidian·Notion 전체 목표는 그대로 유지한다.

**Architecture:** Flutter TextField와 기존 저장 흐름을 유지하며 `TextEditingController.buildTextSpan`으로 같은 원문을 꾸민다. 원문 `text`는 하나이며 서식은 UTF-16 범위의 별도 metadata다. Rust 검색에는 서식 기호를 삽입하지 않은 투영을 전달하고 문서 링크는 그래프용으로 함께 전달한다.

**Tech stack:** 기존 Flutter/Dart·Rust FFI/MCP, 기존 pdf 패키지, 이미 잠긴 characters1.4.1. 새 편집기 프레임워크·서버·전역 설정은 추가하지 않는다.

**Spec:** 이 문서의 설계 결정과 기존 `docs/notion-feature-scope.md`, `docs/library-workspace-design.md`를 따른다. 사용자의 질문 없이 구현 지시에 따라 root가 실행 방식을 결정한다.

## 근거와 설계 결정

- [확인] REA의 실제 Obsidian1.14.4 ASAR SHA146ef847…·선택 app.js SHA958ce57f…를 조사했다. 배포 코드의 명령 등록은 `editor:toggle-bold`→`toggleMarkdownFormatting("bold")`, italics/strikethrough와 Mod+B/Mod+I를 연결한다(선택 app.js byte1961883 근처). 메뉴 상태도 bold/italic/code/highlight/strikethrough를 읽는다. 정적 관측이며 실제 UI 실행을 뜻하지 않는다.
- REA semantic trace ev_8bc707…는 partial/seed0이다. 자동 복원 성공으로 쓰지 않는다. 원 bundle은 `build/research/obsidian/inline-richtext-rea-2026-11-06.json`에 보존했다. 외부 코드·아이콘·브랜드는 복사하지 않고 같은 편집 목적을 자체 구현한다.
- Ruling: 화면은 현재 흰색/teal·기존 글꼴/크기를 유지하고 선택 블록 가까이에 가로 스크롤 서식 도구를 둔다. 굵게/기울임/밑줄/취소선/코드/강조/링크/서식 지우기를 제공한다. — 태블릿·320px 휴대폰·키보드 접근을 함께 지원한다.
- Ruling: 새 서식 페이지는 version3이다. 기존1/2는 읽고 unknown JSON·미디어를 유지한다. 일반 저장의3→2/1 강등을 거절하고, 이력의 명시적 과거 복원은 기존 경로로 유지한다. — 구 앱이 원문만 바꿔 범위를 어긋나게 저장하지 못하게 한다.
- Ruling: 알려진 `inlineData.format=personal-ink-inline-1`만 해석한다. envelope는 `textSha256`과 `runs:[{start,end,marks:[...],link?:...}]`를 가진다. textSha256은 UTF-8 원문 SHA다. 알려지지 않은 payload는 보존하며 서식 동작으로 덮어쓰지 않는다. 이미 알려진 형식에서 digest/범위/표식이 잘못되면 저장을 거절한다.
- Ruling: 범위는 정렬·비중첩·비어 있지 않은 UTF-16 반열림 구간이며 grapheme 경계를 지킨다. 동일 서식의 인접 구간은 합친다. 한글 IME 중에는 서식 명령을 미루고, 텍스트 수정은 선택 범위 및 앞뒤 일치 구간을 이용해 run을 이동한다. 삽입 글자는 왼쪽 스타일을 우선 상속하며 시작점은 오른쪽을 쓴다. 링크 밖 경계 입력은 링크를 자동 확장하지 않는다.
- 링크는 기존 안전한 http/https 또는 검증된 NoteLink만 받는다. 임의 script/file/data URL은 렌더링·실행하지 않는다. 앱의 링크 열기는 기존 onOpenNote/안전한 외부 열기 경로만 쓴다.
- 표 셀·코드 블록 자체·수식·unknown 블록의 새 범위 서식은 후속이다. 일반 텍스트 블록과 미디어/표 설명에는 적용한다. 기존 서식 payload는 블록 종류 전환 때도 버리지 않는다. 이 범위가 전체 Notion 완료를 뜻하지 않는다.

## 고정 인터페이스

후속 Ruling: 실행 취소/다시 실행은 `copyWith(minimumVersion:현재버전)`으로 저장 형식 floor를 유지한다. 이전 opaque payload 때문에 승격이 불가능하면 상태/stack을 바꾸기 전에 거절한다. typed context를 잃는 임시 JSON 왕복은 검증된 inline 모델과 원 children을 재부착한다.

후속 Ruling: `toLinkProjection()`은 상수 label·정규 NoteLink.markdown 경로를 쓰며 `structuredDocumentLinkText()`를 실제 Rust index의 별도 분기로 보낸다. 본문의 열린 fence/HTML/빈 줄이 metadata 관계를 숨기지 못한다. 링크가 있는 Markdown run은 안전한 HTML anchor로 직렬화해 Markdown/브라우저의 중복 entity decode로 주소가 변하지 않게 한다. 직접 DOM href·query 의미를 검사한다. `html:0.15.7`은 기존 잠긴 패키지를 테스트의 직접 dev dependency로 선언한다.

새 `lib/data/vault/block_inline_text.dart`:

- `enum InlineMark { bold, italic, underline, strikethrough, code, highlight }`
- `BlockInlineRun`: `int start,end`, `Set<InlineMark> marks`, `String? link`.
- `BlockInlineSegment`: `String text`, `Set<InlineMark> marks`, `String? link`.
- `BlockInlineText.plain(String text)` / `.fromJson(Map<String,dynamic>, {required String text})`; `static const format`.
- getters `text`, `runs`, `segments`; `toJson()` preserves extra metadata.
- `toggleMark(int start,int end,InlineMark mark)`, `setLink(int start,int end,String? link)`, `clearFormatting(int start,int end)`, `hasMark(int start,int end,InlineMark mark)`.
- `replaceText(String nextText,{int? selectionStart,int? selectionEnd})` rebases text and marks without losing unrelated runs.
- `toMarkdown({String Function(String)? linkDestination})` / `toHtml(...)` escape literal text and safe destinations; formatting ranges crossing line breaks render without active HTML/script content.

`BlockPageBlock.inlineText` returns known typed metadata or null; `copyWith(inlineText:...)` writes it and existing `copyWith(text:...)` rebases it. Explicit inlineText must match the new/current text. `BlockPageDocument.toMarkdown({bool includeInlineFormatting=true})` is the formatted representation. `toSearchText()` keeps the old plain block Markdown structure plus inline document-link projections. Raw1/2 opaque inlineData is never silently reinterpreted.

## Review focus

1. A toolbar tap or keyboard shortcut must keep the intended block/range and must not format the next document after a delayed link dialog.
2. IME composing, Hangul combining characters, emoji/ZWJ and repeated text must retain original text and valid grapheme boundaries after replacement.
3. Saving a version3 page/DB row through an older shape must fail while preserving files, Markdown sidecar, revisions and media.
4. Styling the middle of a word must keep full-word Rust search and inline note backlinks; stale MCP revision/request retry remains guarded.
5. Exported Markdown/HTML/PDF must retain actual text and styles/links without unsafe href execution, missing tail text or silently discarded metadata.

## Tasks and ownership

### 1. Model, persistence, search and history

Files: new inline model; block_page_document.dart; block_page_snapshot.dart; database_media_snapshot.dart if needed; structured_document_text.dart; block_page_history.dart; block_page_history_sheet.dart label; pubspec.yaml/lock for direct locked characters dependency; new model/history/persistence tests.

- [x] Write behavior RED tests through existing JSON/model APIs; root runs and preserves failure.
- [x] Implement fixed interfaces, v3 guards, grapheme-safe toggles/replacement, unknown retention and known digest validation.
- [x] Add dedicated formatting history kind and label; keep plain search plus inline note-link projections.
- [x] Root verifies overlap toggles, insert/delete/repeated text/Unicode, unsafe links, v1/2 unknown data, media/DB downgrade, save/reopen and history.

### 2. Editing UI

Files: block_page_editor.dart; new block_inline_controller.dart if needed; new editor tests.

- [x] Write toolbar/selection behavior RED tests without new production APIs; root runs failure before implementation.
- [x] Render spans and composing underline; preserve selection on toolbar actions and add Mod+B/Mod+I/Mod+U shortcuts.
- [x] Link dialog provides safe external URL and current note choices; apply/remove to captured selection, guard owner/generation/session on completion.
- [x] Reuse document undo/redo/autosave; selection changes do not create revisions. Rebase all text changes including IME; controller updates for undo/document changes must not mark a fresh edit.
- [x] Root verifies 320px/desktop, keyboard, composing, selection retention, failed saves/retry, delayed dialog/document switch and DB row reuse.

### 3. Export, real Rust MCP and integration

Files: portable_document_export.dart; portable_document_pdf.dart; new export and MCP tests; docs/mcp-setup.md with wire example.

- [x] Write export/MCP behavior RED; root runs against real Release61 DLL and Rust stdio executable.
- [x] Render safe formatted Markdown/HTML and chunked PDF rich spans, with supported glyph and unresolved-link reporting. Preserve complete raw snapshot and media.
- [x] Verify actual stdio read/edit/retry/restart, plain full-word search and note link graph, stale revision/readonly/downgrade guards, page and DB row bodies.
- [x] Inspect independent HTML/ZIP and searchable Korean PDF; review rendered sample.

### 4. Final verification and records

- [x] Root runs focused affected tests, analysis, and then full Flutter suite once on frozen source; record exact source/test maps and exits. Do not sum overlapping tests.
- [x] Independent review checks these requirements and data loss/IME/unknown behavior; fix material findings and rerun only affected checks.
- [x] Update README/HANDOFF/scope/history with actual implementation and remaining whole scope. Preserve build61 and distinguish new source from installers until a new build is created.
- [x] No commit/push/publish. Whole goal remains active until full Office/Notion/Obsidian/Android/Windows/Drive/MCP and real device acceptance are proved.
