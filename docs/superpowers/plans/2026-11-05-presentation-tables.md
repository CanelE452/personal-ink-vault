# 발표 표 생성·편집 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Root만 shell·시험·format·native·빌드를 실행한다. 각 task는 test-only → root 실제 RED → 승인된 최소 구현 → GREEN·리뷰 순서다. 이 문서 작성은 구현 시작 지시가 아니다.

**Goal:** 실제 PPT 표의 정체성·grid/span·셀 원문/서식을 노출하고, Windows PPTX에서 검증한 표 생성·셀·행열·병합/분할을 UI와 기존 MCP 저장 경로에 연결한다.

**Architecture:** 기존 `Presentation`의 실제 owner/shape registry에 별도 `PresentationTables`를 결합한다. 변경 전 actual TableShape/Model/cell refs와 raw 상태를 고정하고, 요청에서 계산한 예상 delta만 live·저장·독립 재열기에서 허용한다. authored XML/grid/row extent와 native bounding box를 별도 값으로 유지하며 기존 immutable original/PDF/edition 및 prepared 영수증을 재사용한다.

**Tech Stack:** 기존 Flutter/Dart, Windows LibreOffice UNO/Python, `ink_vault_core`, Rust `ink_vault_mcp`; 새 엔진·서버·의존성은 추가하지 않는다.

**Spec:** [전체 요구와 R6–R8](../../requirements.md), [Office 조사·표 근거](../../office-engine-investigation.md), [기존 발표/Office 설계](../../library-workspace-design.md), [선행 Word 저장 계약](2026-11-04-word-image-mutations.md).

## Global Constraints

- 전체 Android/Windows·Drive·Office 목표의 다음 개발 단위다. 이 계획과 probe를 현재 build54 설치 기능이나 전체 목표 완료로 표시하지 않는다. 경로 링크·저장 재시도 수정을 담은 canonical Windows54/Android136054는 이 표 기능의 새 빌드·설치 수용 gate 전까지 유지한다.
- 이번 첫 write 범위는 검증된 **Windows PPTX의 일반 slide 소유 표**다. master/group/OLE·unsupported model은 관측 가능하더라도 mutation capability를 false로 유지한다. PPT/ODP는 inventory만 확인됐으며 각 형식 mutation gate 전까지 새 표 쓰기를 열지 않는다.
- 원본 bytes·과거 판본·PDF 필기를 보존한다. 모든 편집은 소유 working copy에서 하고 새 original/PDF/edition으로 공개한다. 미리보기는 edition을 쓰지 않는다.
- 이름·텍스트·해시·collection 순서만으로 표/셀을 다시 식별하지 않는다. source revision이 달라지면 새 snapshot을 읽는다. batch alias와 retired ID는 undo branch 뒤에도 재사용하지 않는다.
- raw property의 presence/type/attributes/value/PropertyState를 함께 검사한다. 없는 속성을 만들거나 DEFAULT를 빈 값으로 간주하지 않는다. unknown/부분 목록을 검증된 빈 표 목록으로 바꾸지 않는다.
- native width 차이를 허용 오차 확대나 authored width 대입으로 숨기지 않는다. 기존 master 비교의 tolerance를 표로 확장하지 않는다.
- 기존 Word `tables`/`tableCellText`, PPT shape/design/image 작업, rich text 보호 경계, undo/preview, MCP 권한·판본·prepared 재시도를 보존한다. 외부 구현 코드를 복사하거나 ignored probe를 제품에서 import하지 않는다.
- root가 기존 owned loader/job·시간 한도로 native 작업을 직렬 소유한다. 실패 프로필·원래 실패 로그를 보존하고 다른 Office 프로세스나 retained profile을 추정해 종료·삭제하지 않는다. commit/push·게시·전역 설정 변경은 하지 않는다.

## 확인한 근거와 미확인 범위

- [확인] 현재 `office_worker.snapshot()`의 `tables`, `range_target(targetKind='cell')`, `tableCellText`는 Word 경로다. PPT TableShape는 일반 shape로만 나가고 표 생성·행열·merge/split dispatch는 없다. `Presentation.requires_reopen_verification()`도 현재 design/display 변경만 다룬다.
- [확인] Dart `WindowsOfficeTable`은 `id/ownerId/cells/cellTextDetails`뿐이고 `WindowsOfficeSlide`, `_SlideDraft`, `_PptOwnerState`에는 표 topology/raw 상태가 없다. `_operations()`는 `_PresentationDraft.operations`를 먼저 반환하므로 기존 Word형 `_cells`를 채우는 것만으로 발표 journal에 연결되지 않는다.
- [확인] ignored `build/validation/office-presentation-tables/balanced-pptx-{inventory,position,split}1/result.json`은 PASS/exit0이다. 양수 rows `[3500,3500]`·columns `[7334,7333,7333]` Hmm를 실제 설정·검사했고 split은 `split(1,0)`이다.
- [확인] `balanced-pptx-geometry1`·`balanced-pptx-tall1`은 exit1이다. 요청 XML position/extent·grid 합·row 높이·native height는 exact이나 reopened native width만 −1Hmm여서 `requestedGeometryRetained=false`다. 엄격 실패를 그대로 유지한다.
- [확인] balanced inventory/split의 source XML width 22000Hmm가 no-op/edited XML에서는 21999Hmm로 기록되지만 grid 합은 22000Hmm다. 따라서 위 PASS는 authored extent 전체 보존의 증거가 아니며 글자만 바꿔도 별도 export 검증이 필요하다.
- [확인] `pptx-cells1/rows1/columns1/merge1`은 matrix·일부 caption/notes·PDF·span/content 관측이다. 전체 cell raw style 보존의 제품 gate로 세지 않는다. `balanced-ppt-inventory1`·`balanced-odp-inventory1`은 mutation 근거가 아니다.
- [확인] merged anchor는 `isMerged=false, columnSpan=2`, covered cell은 `isMerged=true, span=1`이었다. `getType()==EMPTY`여도 String은 비어 있지 않았다. 행 삽입 후 기존 cell ref 이동도 equality matrix에 기록됐다.
- [확인] Collabora 선택 JS 3개는 `Notebookbar.ImpressTableDesignTab.js`, `TableMiddleware.js`, `TableResizeMarkerSection.js`다. APK SHA `70b2d7456de59e463efbed1c7382e749f814632b436d2b395f1b0ae1e81ce180`, parent `ev_91060a062f64667bc1a49f17d822ea1bdaf7f7736dfbf755939bb5c68dc24a08`; application unknown701/semantic unknown8353의 부분 정적 관측이다. [binding](../../../build/validation/office-presentation-tables/rea-table-source-binding1.json)·[export](../../../build/validation/office-presentation-tables/rea-tables-and-links-evidence1.json)는 Android 실행 증거가 아니다.

## Review Focus

1. 같은 이름·내용·크기의 두 표, 앞쪽 행/열 삽입 뒤 같은 글자의 셀: 다른 actual object를 편집하지 않아야 한다(Task1/3).
2. span anchor/covered·빈 문단·서식 run·Unicode·보호 field: 텍스트·병합 판단을 편의 getter 하나로 바꾸지 않아야 한다(Task1/2/3).
3. no-op/글자 저장만으로 폭이 1Hmm씩 줄어드는 반복 저장: authored geometry와 native 관측을 분리해 drift를 거부해야 한다(Task1/6).
4. 병합/분할·삭제가 unrelated 셀/shape/notes/master의 raw 상태를 바꾸거나 실패 결과를 남기면 안 된다(Task2/3/6).
5. 구조 편집→undo/redo→늦은 preview·새 source 전환 및 MCP 공개 후 응답 유실: 정확한 journal/token을 보존해야 한다(Task4/5).

## 소유권과 공통 계약

- **Backend worker:** `windows/office_engine/office_presentation_tables.py` 새 모듈과 해당 Python tests; 기존 `office_presentation.py`, `office_worker.py` 연결. native 실행은 root만 한다.
- **DTO/MCP worker:** `lib/data/office/windows_office_engine.dart`, `lib/data/mcp/vault_mcp_service.dart`, Rust schema/tests/README와 DTO/MCP tests. 아래 wire 계약을 먼저 고정해 UI worker와 공유한다.
- **UI worker:** `lib/pages/office/windows_presentation_tables.dart` 새 part, 기존 `windows_presentation_editor.dart`, `windows_office_editor.dart`와 UI tests. DTO 파일을 동시에 편집하지 않는다.
- **Root:** fixture/native 실행·통합·review·문서/빌드/설치 gate. 작업자는 다른 소유자의 변경을 되돌리지 않는다.

**DTO:** Word용 global `snapshot.tables`는 유지하고 `WindowsOfficeSlide.presentationTables: List<WindowsOfficePresentationTable>?`를 추가한다. null=unknown, []=검증된 0개다. slide의 `canAddTable: bool`은 누락 시 false이며 검증된0표에서도 create gate 통과 시에만 true다. table은 `id/ownerId/tableSha256/rowCount/columnCount/rowHeightsHmm/columnWidthsHmm/cells/rawStyle/capabilities`, cell은 `id/row/column/rowSpan/columnSpan/covered/anchorCellId/text/textDetails/rawStyle`을 가진다. 실제 table ID는 기존 actual shape ID와 결합하고 cell ID는 actual ref에 묶는다. 현재 좌표는 ID가 아니다. cell.text는 nullable 원문이며 null과 확인한 빈 문자열을 구분한다. tableSha256도 전체 bound raw 상태를 검증하지 못하면 null이고 새 write capability를 주지 않는다.

`authoredGeometry`는 정확히 연결한 source package의 position/extent/grid/row 값이며 `nativeBoundsHmm`와 별도다. XML 표와 actual Model을 모호함 없이 연결하지 못하면 authored 값은 unknown, 관련 쓰기는 false다. ID/전체 raw 상태에 결합한 `tableSha256`는 비교 수단이며 정체성·권한 검증의 대체물이 아니다.

Task1 wire 결정: authoredGeometry는 `sourcePart/shapeId/positionEmu:{x,y}/extentEmu:{width,height}/columnWidthsEmu/rowHeightsEmu`의 정확한 정수 map이다. nativeBoundsHmm는 `{x,y,width,height}`다. 원본 frame extent와 grid 합이 같은지 추정하지 않는다. rawStyle은 각 property의 presence·declared nativeType·attributes·실제 value·PropertyState를 함께 보존한다. unknown은 absent가 아니다. 읽기 예산은 table `truncated/totalCellCount`(covered 포함 rowCount×columnCount), slide `presentationTableCount/presentationTablesTruncated`로 표시한다. unknown 이유는 `presentationTablesUnknownReason`의 짧은 분류 코드다. complete grid는 전체 anchor partition을 검증하고 partial은 없는 anchor를 추정하지 않는다. 부분/unknown 목록·null fingerprint에 새 write true가 있으면 parser가 모순을 거부한다. capabilities의 닫힌10키는 `canEditText/canEditTextStyle/canEditAppearance/canInsertRows/canDeleteRows/canInsertColumns/canDeleteColumns/canMerge/canSplit/canDeleteTable`이다.

**Closed operations:** 기존 `office_edit` 안에 아래 variants만 추가한다. 모든 기존 표 대상은 `tableId/expectedTableSha256`, 셀 대상은 stable `cellId`를 받는다. source SHA/expectedRevisionId/requestId는 기존 외부 계약을 유지한다.

```text
presentationTableAdd(id, slideId, xMm, yMm, columnWidthsMm[], rowHeightsMm[])
presentationTableCellText(tableId, cellId, expectedTableSha256,
  startUtf16, endUtf16, expectedTextSha256, text)
presentationTableCellTextStyle(tableId, cellId, expectedTableSha256,
  startUtf16, endUtf16, expectedTextSha256, fontSize?, bold?, italic?,
  underline?, color?, fontFamily?)
presentationTableCellAppearance(tableId, cellId, expectedTableSha256,
  fillStyle?, fillColor?)
presentationTableRowsInsert(tableId, expectedTableSha256, changeId,
  index, heightsMm[], templateRow)
presentationTableRowsDelete(tableId, expectedTableSha256, changeId, index, count)
presentationTableColumnsInsert(tableId, expectedTableSha256, changeId,
  index, widthsMm[], templateColumn)
presentationTableColumnsDelete(tableId, expectedTableSha256, changeId, index, count)
presentationTableMerge(tableId, expectedTableSha256, changeId, cellIds[])
presentationTableSplit(tableId, expectedTableSha256, changeId, cellId,
  partsColumns, partsRows)
```

- 새 alias/changeId는 미사용 값이고 신규 cell aliases는 해당 change namespace에서 발급한다. 생존 ref의 ID는 유지하고 사라진 ID는 retired로 남긴다. source 재열기 뒤는 새 snapshot의 IDs를 사용한다.
- 첫 write 상한은 document20표·table100 logical cells·기존 batch100작업이다. 더 큰/부분 inventory는 읽기 상태와 총계를 표시하되 새 mutation은 false다. 행/열 수는 양수, 삭제 후 최소1×1, mm는 기존 geometry 검증처럼 유한·소수 둘째 자리까지·합계 최대1000mm다.
- insert의 새 셀은 비어 있고 명시한 template row/column의 해당 셀 서식을 복제한다. 서식의 raw value/state 보존을 입증하지 못하면 그 insert capability는 false다. 임의 UNO property 이름을 받는 setter는 만들지 않는다.
- merge는 선택한 완전한 사각형의 각 cell paragraph/run 목록을 row-major 순서로 이어 붙인다. 셀 사이 paragraph break는1개이고 원래 빈 문단도 유지한다. 이 예상값을 요청 전에 고정하고 다른 순서·손실을 허용하지 않는다. split은 내용을 첫 anchor에 유지하고 새 셀은 빈 값으로 만든다. `partsColumns/Rows`는 셀의 목표 분할 수이며 native added-divisions 인자와 전체 표 행열 수를 혼동하지 않는다.
- 초기 appearance 쓰기는 검증된 none/solid fill·RGB뿐이다. 나머지 border/padding/정렬 raw 상태는 노출·보존하며 별도 setter/native gate 전까지 쓰기를 열지 않는다. generic shape text/geometry가 표를 우회하지 않게 하고, `shapeDelete`는 검증된 표 전체 삭제 delta를 ledger에 반영한 경우만 허용한다.

## Task 1: actual 표 catalog와 authored/native 분리

### Source 결합·저장 권위 후속 결정 — 2026-11-05

private connector v2는 source4표를 actual owner/TableShape/Model/cell refs에 일대일 연결했지만 connector Visible=true로 원래 hidden gate는 실패했다. 이 실패는 보존한다. 제품의 새 수명주기 계약은 **임시 추적 객체가 private import 안에만 존재**하는 것이다. 실제 refs 결합, 발급한 모든 객체 제거와 원래 refs/count/metadata 재검증이 끝나기 전에는 document를 caller에 반환하지 않으며 snapshot/fingerprint/preview/PDF/save·외부 callback을 허용하지 않는다. 실패 시 문서를 닫고 어떠한 결과도 공개하지 않는다. source hidden 보존을 이 새 계약의 근거로 쓰지 않는다.

`office_presentation_source.open_pptx_tables(path)`는 동일하게 검증한 소유 archive image와 catalog를 한 context 안에서 제공한다. source SHA를 확인한 뒤 source path를 다시 열어 다른 image의 unrelated members와 섞지 않는다. context 진입 전과 반환/실패 시 source 변경을 검사하고 자원을 닫는다. 기존 `read_pptx_tables`의 반환 계약은 유지한다.

private binding copy는 변경된 XML을 포함한 전체 expanded ZIP payload 합계와 개별 member를128MiB로 제한하고 payload 복사 전에 검사한다. 이는 압축 파일 길이와 다른 별도 작업 예산이다. Windows의 tagged file은 읽기 공유만 허용하는 native handle을 context 수명 동안 유지해 loader의 읽기 중간과 lazy read 동안 쓰기·교체를 막는다. handle을 얻은 뒤 identity/SHA를 다시 검증하며 성공 문서를 닫은 후 handle→소유 file 순서로 정리한다. pre/post hash만으로 tagged A→B→A를 허가하지 않는다. 이 native binding은 검증된 Windows 경로이며 순수 source reader의 플랫폼 범위를 줄이지 않는다.

신규 `office_presentation_binding.py`는 위 image만으로 private tagged PPTX를 만들고 exact issued owner/connector ledger→StartShape→Model/cells를 결합한다. Name/본문/좌표/순서 fallback·원래 metadata setter는 없다. `office_presentation_text_source.py`는 실제 source cell의 UTF-16/legal XML byte boundaries와 보호 구간을 읽는 기반이다. 두 모듈의 단위·실제 native gate와 public 전달 연결 전에는 authored/source 권위를 공개하지 않는다.

향후 source text patch는 full native raw `tableSha256`와 별도 권위 분기를 사용한다. null full fingerprint를 source SHA로 채우거나 기존 native-operation guard를 제거하지 않는다. source revision/package SHA/part/shapeId/frame SHA·actual binding·text/range SHA 및 immutable image를 결합하는 wire/DTO/backend/MCP/UI 변경과 독립 clean reopen/PDF/no-op→text→no-op gate가 먼저다. native 19999Hmm/authored 20000Hmm은 각각 검증하며 기존 geometry 실패를 재분류하지 않는다. full/paged read·rich/style·생성/행열/merge/split·master/group·혼합 batch·전체 Android/Windows/Drive 목표는 계속 요구다.

**Files:** Create `windows/office_engine/office_presentation_tables.py`, `windows/office_engine/test_presentation_tables.py`; modify `windows/office_engine/office_presentation.py`, `windows/office_engine/office_worker.py`, `lib/data/office/windows_office_engine.dart`; create `test/office/windows_presentation_tables_test.dart`.

순수 source 결합 기반은 `windows/office_engine/office_presentation_source.py`와 `test_presentation_source.py`다. `read_pptx_tables(path)`는 hash가 일치한 소유 byte view의 원래 slide part와 source ID, geometry/topology 및 half-open UTF8 spans를 반환한다. fixed transitional PPTX/일반 slide table의 bounded reader이며 native marker 결합이나 write 권한을 대신하지 않는다. `test_worker_inspect_cleanup.py`, `test_presentation_value_types.py`는 실제 실패 원인 보존과 nominal interface 조회 차단을 별도로 검사한다.

**Interfaces:** `PresentationTables(presentation, document, source_path)`; `snapshot(owner_id) -> list | None`, `assert_fresh()`, `apply(operation)`, `verification_state()`, `verify_reopened(expected)`. `Presentation.owners/shape_items/register_shape/assert_fresh`의 actual binding을 재사용한다.

- [x] 기존 `office_worker.snapshot()`을 통한 RED: source0/unknown 구분, 중복 이름/내용 표2개, TableShape 결합 뒤 Model 생성, 겹치지 않는 anchor/covered topology, EMPTY getter와 nonempty String, raw property missing/DEFAULT/nonempty를 검사한다. 새 API import/컴파일 실패를 동작 RED로 세지 않는다.
- [x] root가 `python -B -m unittest discover -s windows/office_engine -p test_presentation_tables.py`의 실제 assertion RED를 확인한 뒤 catalog/DTO만 구현한다. 처음에는 모든 새 write capability가 false여야 한다.
- [x] actual shape/Model/cell refs를 source-bound registry에 고정한다. text/count/좌표로 ref를 재결합하지 않는다. 모델·span·raw state가 unknown이면 부분 목록/이유를 보존하고 false로 닫는다. `LeftBorder` 선언형과 실제 BorderLine2 값, 없는 `*Border2/VerticalJustify/IsProtected`를 구별한다.
- [ ] source XML table과 actual owner/Model의 정확한 결합, authored extent/grid/rows와 native bounds를 각각 캡처한다. no-op·text-only 저장에서도 authored extent를 보존하는 gate를 작성한다. 순서/동일 문자열로 XML 표를 추정하거나 `shape.Size.Width`를 authored width로 재사용하지 않는다.
- [ ] root가 DTO 및 기존 presentation registry 회귀를 GREEN으로 확인한다. 폭 −1Hmm의 원인/예상 계약을 아직 입증하지 못하면 geometry-dependent capability를 계속 false로 둔다. 기존 geometry/tall 실패를 PASS로 재분류하지 않는다.

## Task 2: 셀 원문·서식 편집과 새 표 생성

### 원본 text patch 경로의 명시적 계약

`presentationCellTextPatch`를 기존 native `presentationTableCellText`와 별도 closed operation으로 추가한다. exact fields는 op/authorityVersion(1)/ownerId/tableId/cellId/expectedSourceSha256/sourcePart/shapeId/expectedSourceFrameSha256/expectedTextSha256/startUtf16/endUtf16/text다. source SHA는 operation과 root request에서 일치해야 하며 sourceRevision/expectedRevisionId/requestId는 기존 Office 세션·MCP prepare/commit 영수증으로 고정한다. package/frame SHA는 배치 입력 기준, text SHA/UTF-16은 앞선 operation 이후 현재 셀 기준이다. source authority는 full native tableSha의 대체값이 아니며 기존 native write guard를 제거하지 않는다. source 전용 배치는 최대100개이고 native export와 혼합된 배치는 변경 전에 명시 거부한다. 혼합 배치 수용은 계속 후속 요구다.

향후 table.sourceTextPatchAuthority는 closed kind/version과 sourceSha256/sourcePart/shapeId/frameSha256를, cell.sourceTextPatch는 원문·UTF-16·text SHA·지원 범위를 전달한다. byte offsets/UNO refs는 공개하지 않는다. 현재는 이 권위를 발행하거나 새 쓰기를 열지 않는다. backend·DTO·MCP·UI와 clean 독립 재열기/PDF/3회 저장 검증 뒤에만 별도 source-text canReplace를 허용한다. 기존 native canEditText 및 unknown full raw fingerprint는 그대로 유지한다.

이행할 typed cell wire는 canReplace/truncated/text/utf16Length/textSha256/segments/protectedRanges의 닫힌7필드다. segments는 startUtf16/endUtf16/editable의 닫힌 map이며 protectedRanges는 startUtf16/endUtf16/reason이다. reason은 field/hyperlink/comment/processingInstruction/lineBreak/paragraphBoundary 중 하나다. UTF-16 최대131072, segments/protectedRanges 각4096개다. 셀 covered 여부·전체 grid·source part/id·source SHA와 실제 core text를 검사하고 master 권한을 열지 않는다. 선택 endpoint는 scalar 경계여야 한다. 정상 저장 snapshot은 candidate authority, 미리보기 draftSnapshot은 원래 package/frame authority와 요청 후 current text/maps를 유지한다. UI는 draft의 원래 guard를 preview 결과의 새 guard로 교체하지 않는다.

draftSnapshot의 native cell.text/textDetails/rawStyle/tableSha/capabilities는 원래 관측 baseline으로 보존하고 요청 후 current 값은 독립 sourceTextPatch에만 담는다. 기존 office_workspace는 이 draftSnapshot을 WindowsOfficeDraftPreview.snapshot으로 전달한다. DTO는 두 분기를 같은 현재 native 관측으로 혼동해 전역 text equality를 강제하지 않으며 source proof 자체의 text/hash/UTF-16·geometry/sourceSHA·grid 모순을 검사한다. backend는 정상 source proof 발행 전 실제 core 원문 일치, apply에서 fresh 실제 대상과 순차 요청, candidate에서 독립 재열기 검증을 담당한다. UI는 journal에서 계산한 source delta와 origin native baseline 보존을 확인한다. 이 projection이 raw 현재값·native write 권한을 새로 증명하는 것은 아니다.

version1 UI는 공개되지 않은 lexical 종류/run ID를 추정하지 않는다. 미리보기의 같은 의미인 인접 editable 구간 분할·병합은 정규화해서 비교하되 원문/hash/UTF-16과 field/hyperlink/lineBreak/paragraphBoundary의 의미적 보호 위치·종류·scalar 삽입 안전성은 요청에서 계산한 기대값과 같아야 한다. 보호 zero-width boundary를 정규화하며 지우지 않는다. comment/PI는 원본 markup bytes 보호이며 의미적 텍스트 금지 구간이 아니므로 private writer의 exact bytes 검증으로 보존한다. native baseline·다른 셀·geometry·origin 권위의 무관한 변경은 그대로 거부한다.

원본 글자 분기는 별도의 `SourcePatchBudget`으로 정확한 JSON bytes/nodes를 계량하고 `sourceTextPatch.truncated`를 필수로 전달한다. source inventory/grid·원문·UTF-16·보호/affinity map 또는 actual binding/native core text 관측이 불완전하면 권한은 false다. 필수 truncated가 없다고 false로 해석하지 않는다. native RAW 출력만 예산에 잘린 경우에는 부모 `truncated=true`, native tableSha=null, native canEditText=false를 그대로 유지하면서 별도로 완전한 source proof를 전달할 수 있도록 DTO/MCP의 분기를 명시적으로 개정한다. 이는 native core 실패를 RAW 출력 손실로 바꾸거나 full native raw 권한을 복원하는 규칙이 아니다. 현재 제품에는 이 새 분기/권한이 아직 없다.

순수 `patch_cell_text`는 정확한 source mapper의 법적 UTF-16/lexical byte 경계만 바꾼다. 새 문자열은 첫 선택 run의 서식을 따르고 나머지 선택된 text 조각만 제거한다. 공유 삽입 경계에서는 source 순서상 왼쪽의 첫 법적 editable 위치를 사용한다. rPr/pPr·주석/PI·CDATA 구분자·unknown attrs·다른 frame은 재직렬화하지 않는다. field/hyperlink/구조적 break/지원하지 않은 문법은 명시적으로 거부하며 전체 rich/style·문단·CDATA 확장 요구는 계속 남는다.

순수 package writer `patch_pptx`는 같은 소유 archive image에서 source part/shapeId/셀 좌표와 origin frame SHA를 고정하고 위 cell patch를 순서대로 적용한다. 변경하지 않은 member의 압축 데이터와 local records를 raw-copy하며 central directory는 필요한 offset만, 변경 member는 CRC/size와 해당 data descriptor만 갱신한다. no-op은 전체 원본 bytes/SHA 그대로다. 원본 signature가 무효화되는 signed package는 검증 근거 없이 편집하지 않는다. 저장 후보는 별도 파일로 만들고 파싱·CRC·원본/그리드·정확 bytes를 검증한 뒤 기존 prepared 경로로 넘긴다.

ZIP 구현 근거는 [PKWARE APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)의4.3.7/4.3.9/4.3.12/4.3.16과 [Python ZIP 문서](https://docs.python.org/3.13/library/zipfile.html)다. 지원하는 일반 stored/deflate·single disk·non-ZIP64 범위는 기존 strict source reader와 같으며 새로운 전체 Office fidelity의 주장으로 확대하지 않는다.

[확인] 내부 mapper/순수 글자 patch/package writer와 일반 inspect 연결은 구현됐다. bundled Python366PASS, 실제 일반 stdio22 읽기 PASS, source no-op→text→no-op의 clean 재열기·별도 ref 관측6서버와 제한된 PDF glyph/pixel proof를 얻었다. `tables-read-checkpoint5.json`에 source631 지문과 stdio22 이후 두 helper 보강의 차이도 기록한다. PDF 추출 공백 strict FAIL은 별도 보존한다. 이 내부 gate는 아직 없는 public operation/DTO/MCP/UI/권한·prepared 저장·실기기 수용을 대신하지 않으며 아래 Task2 전체 체크는 열어 둔다.

**Files:** Modify `windows/office_engine/office_presentation_tables.py`, `windows/office_engine/office_worker.py`, `windows/office_engine/office_text.py`; extend `windows/office_engine/test_presentation_tables.py`; create `windows/office_engine/test_presentation_tables_native.py`.

**Interfaces:** 위 cell/add variants를 `PresentationTables.apply()`에서만 처리한다. `tableSha256`/text SHA/UTF-16 및 exact cell ref를 검사한 뒤 예상 ledger를 먼저 만들고 기존 `office_text`의 검증된 range primitive를 사용한다. legacy Word `tableCellText`는 바꾸지 않는다.

- [ ] root RED: duplicate text 셀·covered cell·surrogate 중간·보호 field·stale SHA·다른 owner·첫 mutation 전 raw drift를 변경 전에 거부한다. 범위 밖 cell paragraphs/runs·fill/border/padding·다른 shape/notes/master가 byte/raw 의미로 같은지 검사한다.
- [ ] RED 후 text/range style·fill을 각각 구현하고 개별 GREEN/native gate를 닫는다. cell 전체 String 대입으로 rich runs를 재생성하거나 현재 live 상태를 새 expected baseline으로 채택하지 않는다.
- [ ] root RED 후 create를 구현한다. page에 결합된 actual TableShape/Model을 검증하고 양수 row/column 크기를 명시한다. 새 객체 delta가 정확히1표이고 기존 표·셀 ref와 raw 상태가 그대로여야 한다. 0→1 표, 같은 alias로 후속 셀 편집, alias 재사용 거부를 검사한다.
- [ ] root native `--case cells`와 `--case create`는 제품 worker 저장→PDF→별도 owned loader 재열기를 실행한다. 단순 matrix 성공과 raw style 전체 보존을 분리하고, authored width/grid/rows·native bounds를 각각 검사한다. 어느 단계든 실패하면 edited/PDF/edition을 남기지 않고 원본 SHA는 같아야 한다.

## Task 3: 행열과 merge/split의 예상 변환

**Files:** Modify `windows/office_engine/office_presentation_tables.py`, `windows/office_engine/office_presentation.py`, `windows/office_engine/office_worker.py`; extend `windows/office_engine/test_presentation_tables.py`, `windows/office_engine/test_presentation_tables_native.py`.

- [ ] 각 op별 unit RED→최소 구현→GREEN을 분리한다. 앞/중간/끝 insert/delete, 동일 글자 셀, source0, 마지막 행열 삭제, bounds/count0·상한, 병합을 가르는 삭제/삽입, 잘못된 donor/covered target·stale table SHA를 포함한다.
- [ ] insert/delete의 정확한 source→destination 좌표 변환을 요청에서 계산하고 생존 cell actual ref equality·원문/raw state를 검증한다. 새 셀/retired refs만 허용한 delta로 기록하며 서식·문자열을 검색해 ID를 다시 붙이지 않는다.
- [ ] merge/split의 사각형·span partition·내용 정책을 native 호출 전에 고정한다. 첫 단계는 기존 merged span을 완전히 포함하는 안전한 영역만 허용한다. 교차/부분 merge, protected content 또는 보존 불가능한 raw run은 변경 전에 거부한다.
- [ ] split 회귀는 기존 `split(2,1)`의 2×3→3×4 관측을 실패 근거로 유지하고, merged1×2의 `parts=2×1`→native `(1,0)`→전체2×3을 별도로 검사한다. 더 큰 분할은 요청에서 계산한 전체 grid·새 셀·content 예상값을 native/reopen에서 입증한 뒤 해당 capability만 연다.
- [ ] root native `--case rows`, `columns`, `merge`, `split`을 각각 직렬 실행한다. 새 writer의 `has_presentation_tables`/reopen 검증 및 failure cleanup에 연결하고, 기존 design/display touched 여부와 무관하게 표 작업도 독립 재열기를 반드시 수행한다.

## Task 4: 발표 UI draft·undo/preview

**Files:** Create `lib/pages/office/windows_presentation_tables.dart`, `test/office/windows_presentation_tables_editor_test.dart`; modify `lib/pages/office/windows_office_editor.dart`, `lib/pages/office/windows_presentation_editor.dart`; extend `test/office/windows_presentation_design_editor_test.dart`.

**Interfaces:** 새 part의 `_PptTableDraft/_PptTableState`를 `_SlideDraft`, `_PptOwnerState`, `_PptCheckpoint`, `_PresentationDraft.record/_restore/refreshPreview`에 결합한다. cell selection·grid/span·raw fingerprint·alias/retired ID·전체 journal을 checkpoint에 포함한다.

- [ ] widget RED: 검증한0표에서 생성 버튼, table/cell 선택, safe target만 편집, create→셀→행열→merge/split undo/redo, 320px·키보드/IME composing·마지막 행열 거부를 검사한다.
- [ ] root RED 후 UI를 붙인다. 표는 실제 PPT 표 작업으로 저장하며 TextShape나 이미지로 대체하지 않는다. 기존 Word `_cells` 경로를 발표 journal에 무작정 합치지 않는다. raw internal 명칭 대신 셀/행/열/서식이라는 사용자 작업을 표시한다.
- [ ] 구조 변경은 기존 design preview처럼 pending checkpoint→source-bound native preview 검증→승인된 ID/grid/raw delta 반영 순서다. 검증 전 live snapshot 전체를 신뢰해 draft를 덮지 않는다. 지원하지 않는 표/geometry 작업은 비활성 사유를 표시한다.
- [ ] root RED/GREEN: undo/새 편집/owner·source 교체 후 늦은 preview, 틀린 owner/grid/retired ID, preview 실패·저장 실패/재시도, 창 닫기·재열기를 검사한다. 새 preview가 source original을 저장하지 않고 성공 전 dirty/journal을 지우지 않아야 한다.

## Task 5: MCP typed 계약과 prepared 저장 재개

**Files:** Modify `lib/data/office/windows_office_engine.dart`, `lib/data/mcp/vault_mcp_service.dart`, `packages/ink_vault_mcp/src/server.rs`, `packages/ink_vault_mcp/README.md`; create `test/mcp/office_presentation_tables_test.dart`; extend `test/mcp/office_prepared_receipt_test.dart`, `test/mcp/stdio_end_to_end_test.dart`, `packages/ink_vault_mcp/tests/stdio.rs`.

- [ ] root RED: closed fields/types/bounds, null/unknown/[], 중복 alias·다른 source/owner/cell·잘린 grid/span·stale table/text SHA를 검사한다. MCP snapshot은 기존20표/100셀 read budget과 totals/truncated를 유지하고 불완전 표에는 새 write capability를 주지 않는다.
- [ ] DTO factories/Python dispatch/Rust `OfficeOperation` variants의 이름·필드를 위 계약과 일치시킨다. `deny_unknown_fields`와 기존 전체 operation budget을 유지하고 새 tool이나 직접 파일 쓰기 경로는 만들지 않는다.
- [ ] 기존 `_recordedOffice` v2와 `OfficeDocumentStore.prepareEdited/resumePreparedEdition/commitPreparedEdition`을 재사용한다. exact operations·source revision·root/vault/device/format과 편집 원본/PDF/edition bytes를 공개 전에 결합한다. 표 쓰기 때문에 별도 receipt version/우회 writer를 추가하지 않는다.
- [ ] root RED/GREEN: 최종 publish 직전 권한 철회, metadata/source race, prepared/완료 응답 유실·full restart·뒤늦은 descendant ACK, 실제 manifest/files 손상·nofollow·legacy 호환을 검사한다. 동일 request 재개는 native 표 mutation을 다시 실행하지 않아야 한다.
- [ ] root가 Rust SDK 회귀와 실제 stdio→앱→native table→immutable edition→독립 재열기까지 확인한다. `read_document`의 전체 cell raw 상태·capability를 실제 노출하고 parser만 통과한 상태로 완료하지 않는다.

## Task 6: native 수용·회귀·출시 경계

**Files:** Root가 `docs/office-engine-investigation.md`, `docs/mvp-validation.md`, `HANDOFF_KO.md`, `_docs/history/2026-11-05.md`(실행일이 바뀌면 기존 일별 파일)와 이 계획의 실제 진행을 갱신한다.

- [ ] source/runtime/helper SHA 고정 후 root가 Python→Dart DTO/UI/MCP→core/Rust→실제 native groups를 확인한다. 명령 예시는 `python -B -m unittest discover -s windows/office_engine -p test_presentation_tables.py`, `flutter test test/office/windows_presentation_tables_test.dart test/office/windows_presentation_tables_editor_test.dart test/mcp/office_presentation_tables_test.dart`, `cargo test --manifest-path packages/ink_vault_mcp/Cargo.toml`다. native 그룹은 기존 owned wrapper/timeout 안에서 case별 직렬 실행한다.
- [ ] native control은 원본·no-op·요청 예상 ledger·제품 결과를 별도 기록한다. source→no-op→재저장3회의 authored XML extent/grid/row 및 native bounds를 함께 검사해 누적 width drift를 잡는다. geometry/tall의 기존 −1Hmm 실패는 해결 근거 없이 tolerance/expected 값 변경으로 통과시키지 않는다.
- [ ] raw whole cell properties/paragraph/runs와 unrelated shape/notes/master·media·slide 순서·원본 bytes·PDF 내용을 검사한다. setter·inventory delta·raw mismatch·export·독립 reopen fault 후 edited/PDF 미공개와 owned handle 폐쇄를 확인한다. 단순 PDF page 수만으로 보존 성공을 세지 않는다.
- [ ] fresh review와 전체 Flutter/분석·SDK·실제 설치된 writer/stdio 검증 후에만 새 Windows/Android 묶음의 canonical 승격을 진행한다. PPT/ODP 쓰기는 각각 별도 native mutation suite 후에만, Android Collabora/S9+·Microsoft Office·두 기기 Drive 왕복은 실제 수용 전까지 미검증으로 남긴다.

## 남은 위험과 중단 기준

- source XML authored table와 native Model의 확실한 연결, no-op authored extent 손실 및 native width −1Hmm 관계는 아직 제품 해결책이 아니다. Task1의 read-only catalog와 쓰기 capability gate를 분리해 증거 없는 편집을 열지 않는다.
- 원본에 없는 property/unknown Model inventory·복잡한 merged grid·동일 native value지만 다른 PropertyState·필드/하이퍼링크/혼합 runs는 안전한 요청 전 예상값을 만들 수 없으면 거부한다.
- split의 local parts와 전체 table 확장, merge의 문단/run 순서, 새 셀 default/상속 스타일은 실제 저장·재열기 결과까지 고정해야 한다. 현재 probe의 matrix/span 성공으로 일반화하지 않는다.
- Task1 catalog/DTO 제품 코드와 실제 RED·native inspect/Dart wire 검사를 진행했다. source binding·저장 보존과 검토 발견 사항의 수용은 아직 남아 있으며, Tasks2–6의 표 mutation/UI/MCP/출시 gate는 시작하지 않았다. 전체 계획 완료로 표시하지 않는다.

## 2026-11-06 후속 진행

### 공개 구조 생성 연결 계약 — 구현 중

기존 전체 목표와 Tasks2–6를 유지하고 실제 source writer를 UI/MCP/prepared 저장으로 연결한다. 첫 공개 구조 batch는 `presentationSourceTableAdd` 전용이며, 생성 뒤 셀/행열/서식을 같은 journal에서 순차 편집하는 최종 요구는 별도 미완료 항목으로 유지한다. legacy source text/native batch를 새 규약으로 묵시 변환하지 않는다.

- Slide의 별도 `sourceStructureAuthority`는 kind=`sourceStructure`, version=1, sourceSha256/sourcePart/partSha256/shapeIdInventorySha256/shapeIdCount/canAddTable의 닫힌8필드다. exact actual owner binding 뒤에만 발행하며 모든 numeric cNvPr ID를 정렬한 canonical JSON SHA를 사용한다. native full-RAW tableSha와 legacy canAddTable=false는 유지한다.
- 새 operation의 닫힌12필드는 op/authorityVersion/id/ownerId/expectedSourceSha256/sourcePart/expectedSourcePartSha256/expectedShapeIdInventorySha256/xMm/yMm/columnWidthsMm/rowHeightsMm다. alias는 `new-table-[A-Za-z0-9_-]{1,64}`, batch는100개 이내/중복 alias 금지다. public guards는 원본 기준이고 private writer에는 직전 결과의 part SHA를 계산해 순차 전달한다.
- 새 detached plan은 `piv.structure-plan/1`이다. top-level8필드는 converted/parts/expected_native/expected_core/source_order/owner_ledger/additions/base_snapshot이며 기존 `piv.source-plan/1` decoder는 유지한다. schema·request·phase·source SHA와16MiB/524288nodes·XML8/32MiB·4096parts 및 no-follow/file lease를 검사한다.
- 구조 preview는 `structuralPreview`의 kind=`presentationSourceStructure`, version=1, baseSourceSha256/candidateSourceSha256/operationsSha256/additions/snapshot의 닫힌7필드다. alias receipt는 alias/ownerId/tableId/sourcePart/shapeId/frameSha256다. candidate snapshot을 원본 SHA의 legacy draftSnapshot으로 가장하지 않는다.
- plan/render/observe는 별도 family dispatch와 fresh exact binding을 사용한다. 새 표는 실제 Model row/column 크기·partition·complete empty core/proof를 필수 검사하고, 기존 표/native projection·core·owner·masters를 보존한다. nativeBounds와 authored geometry의 차이는 별도 관측하며 tolerance로 숨기지 않는다.
- 직접 renderer는 PDF의 exclusive 생성 identity를 export 이전에 소유해야 한다. 기존 foreign PDF와 예외 시 처음 발견한 파일을 소유권으로 채택하지 않는다. 기본 embedded export의 기존 lease/handoff는 명시적인 private `export_owns_output=True`로 재사용한다. LibreOffice의 [MediaDescriptor Overwrite](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1document_1_1MediaDescriptor.html)는 현재 default TRUE이며, global exporter 권한은 바꾸지 않는다.

현재 실제 검사: worker7/embedded family6/legacy+structure wire21/backend21 PASS다. PDF 소유권5개 RED 후 직접 renderer는 배타적 PDF inode를 export 전에 소유하고 예외 시 foreign output을 채택하지 않도록 수정했다. Rust 전체는36PASS/exit0(9+12+15), 실제 Release 공통 DLL9PASS/exit0이다. DTO/preview/factory/engine 신규28+MCP13은41PASS이고 최종 UI22PASS다. 기존52개까지 포함한 focused 실행은114PASS/1FAIL(반복 dialog fixture)이었고, 해당 test만 route 종료 조건을 명시해 최종 UI22개에서 통과했다. 서로 겹치는 수를 합산하지 않는다. 모든 실패와 preimage를 `build/validation/office-presentation-tables/structure-public1/`에 보존한다.

새 Rust main build는44.78초/exit0/SHA360e71ba…다. 현재 source654/909caed8…의 전체 Flutter1556PASS/108skip/0FAIL, Python517PASS/138.803초, 분석 문제0/7초는 각각 exit0이며 전후 지문이 같다. root/test411파일 SHA는5ab80d2e…로 전후 동일하다. 7f00153a… source의 앞선 Python1은517개 중516PASS/1FAIL/133.721초였고 단독 진단1회·전체 진단2회에서는 ACK WinError32가 재현되지 않았다. 원 예외 파일/경계는 아직 미확정이며 원 실패를 지우거나 해결로 바꾸지 않는다.

[확인] 실제 SDK/service/default-native 생성·동일 요청 재시도·fresh read는 public2에서1PASS/59.346초다. 그 다음 실제 생성된 표의 셀에 한글😀를 넣고 각 원본/생성/수정 판본을 보존하며 각 요청 replay 무중복·최종 재열기를 확인한 roundtrip1은1PASS/102.230초다. source9c387912…→a7623cdd…와 새 framef46d6cbd…를 실제 판본·파일·source parser/native proof로 결합했다. native generic text의 null은 RAW unknown으로 유지하고 full source/core proof와 분리한다. 잘못된 native 빈 문자열 기대의 SDK1 실패를 보존한 뒤 기존 계약 추적·MCP14개·보존 정상1/음성32개 검사로 checker를 검증하고 실제 수용을 재실행했다. 현재 생성과 후속 셀 입력은 각각 저장하는 두 batch이며 한 journal에서 혼합 구조/셀/서식을 편집하는 최종 요구는 여전히 미완료다. 새 설치 묶음·Android 구조 API/실기기·외부 LLM gate도 미완료다.

[확인] public native1은 실제 기본 CLI의 원본 inspect→source 권위 기반 생성→같은 원본에서 독립 생성→후보 fresh inspect4단계, 실제 fresh Office process8개/exit0이다. 원본01de5906…와 helper29/runtime18·harness pins는 전후 같고, 두 생성 후보는9c387912…로 byte 동일하다. 기존2표/8셀과 새2×3표/6셀의 완전한 source/core·정확 Model 열3000×3/행1200×2Hmm, source authored geometry·typed receipt/operations digest·PDF·자연 종료/Job0/handle/profile 정리를 확인했다. nativeBounds 폭8999 대 authored9000Hmm와 RAW truncation은 별도 관측한다. report SHA는 `11f5a25040eb49421774c487fde4fd4a3533e20ad1c5ed4e82fc7b8698e5ea78`다. 이후 UI/MCP service·prepared 저장/replay는 위 source SDK 통합으로 확인했으며 새 설치본/실기기 수용은 남았다.

### 구조 쓰기 구현 결정 — 원본 구조와 native 검증 분리

Ruling: 표 구조 쓰기는 원본 OOXML의 정확한 byte 변환과 fresh native 의미 검증을 결합한다. native 전체 RAW fingerprint가 unknown인 상태를 source hash로 대체하거나 기존 capability10개를 true로 바꾸지 않는다. 현재 글자 분기처럼 별도 `sourceStructureAuthority`를 도입하고, 실제 TableShape/Model/grid/cell·요청한 서식을 필수 검증한 작업만 UI/MCP에 연다. 원본 전체를 native export하는 방식에서 관찰한 authored extent의 −1Hmm 손실을 숨기지 않기 위한 결정이다. 잘못된 경우 source 구조·native 관측의 불일치로 후보를 거부하며 원본과 기존 판본은 보존한다.

현재 canonical baseline은 Windows55/Android136055다. 위54 표시는 당시 기록이며 새 구조 기능이 포함됐다는 뜻이 아니다. 전체 Tasks2–6·Android/Windows/Drive·Office/Obsidian/Notion·외부 LLM 목표는 유지한다.

다음 체크리스트는 Task2 create의 실행 단위이며 전체 표 기능의 대체 완료 기준이 아니다.

- [x] Test-only `test_presentation_structure.py` → root RED → 제품 `office_presentation_structure.py`: 기존 slide에 inline `p:graphicFrame/a:tbl`을 추가한다. positive 미사용 numeric cNvPr ID를 slide 전체에서 할당하고 locally declared namespace로 만든다. 기존 XML byte와 관계·압축 ZIP member를 보존한다. extLst는 마지막에 유지한다.
- [x] 내부 `add_table_part(bytes, source_part, operation)`과 `add_tables_pptx(source, destination, operations, expected_source_sha256)`는 sourcePart/expectedSourcePartSha256/xMm/yMm/columnWidthsMm/rowHeightsMm의 닫힌6필드를 사용한다. 후속 operation의 part SHA는 직전 결과 기준이다. mm는 유한 int/float, 소수 둘째 자리까지, 좌표 ±1000mm/양수 행열·합1000mm, 100ops/20tables/100logicalcells와 XML8/32MiB/package128MiB를 변경 후에도 검사한다. 이 내부 API는 공개 edit 권한이 아니다.
- [x] 원본·후보의 정확 byte delta/새 표 metadata·기존 표와 다른 ZIP records·서명/stale/alias/foreign output·실패 cleanup을 검사한다. 신규 빈 셀은 기존 source text mapper로 Unicode를 실제 입력할 수 있어야 한다.
- [x] 기존 owned embedded inspect를 사용해 새 후보의 actual TableShape/Model과 complete grid/text/geometry, 기존 표, clean PDF 및 별도 fresh binding을 실행 검증한다. 단순 parser 성공으로 native 수용을 표시하지 않는다. source/Model geometry와 nativeBounds 관측을 구분하며 일반 fidelity 완료로 확대하지 않는다.
- [ ] 별도 구조 authority/닫힌 예상 ledger/stage wire를 연결하고, create와 후속 셀·행열·merge/split/style의 순차 모델·stable mapping을 구현한다. 기존 text plan을 느슨하게 만들지 않는다.
- [ ] DTO/UI/MCP와 prepared immutable 저장·같은 request replay·독립 재열기 및 새 설치 묶음 gate까지 실행한다. 기존 native false flags와 지원하지 않는 형식의 폐쇄를 유지한다.

실행 기록: root의 source23개 RED는 API 부재를 명시한104개 assertion 실패였고 구현 후23PASS다. 실제 파일의 소유 candidate 실패 제거·동일 bytes/다른 inode foreign 교체 보존·원본 변경·검증 후 동일 inode 변경5개도 PASS다. 전체 Python468PASS/96.921초/exit0, 전후 source647/323359c1… 동일이다. default CLI의 native1은 기존2→3표/14셀·빈 셀 Unicode·PDF·fresh reopen을3개 process에서, native-zero1은 실제 빈 owner0→1표/6셀을2개 process에서 확인했다. 모든 실제 process 자연 종료0·Job/handle 정리를 통과했다. native width8999 대 authored9000Hmm, Unicode native height2471 대 authored2400Hmm는 분리 관측하며 geometry fidelity gate는 열어 둔다. source/full RAW 권위·UI/MCP/prepared 저장은 미연결이다. 현재 text preview의 base SHA·원래 table/shape 개수 불변 규칙을 완화하지 말고 새 structural preview/adoption 경로를 만든다.

실제 REA 분석 기록은 `build/validation/office-presentation-tables/structure-create1/rea-evidence.json`에 보존했다. APK3개 JS byte binding 후 parent `ev_522fb19d92e829b6afe517e21df0d8bd81b5a384c7c421db3697b32b661dd3d2`와 TableDialog 정적 trace `ev_950f4d5182c58536ca47f883a00c8ff66128abccdd7df269fb484786aaa8948f`를 얻었다. application unknown701/semantic unknown8353의 부분 정적 분석이며 Android 실행 성공의 근거가 아니다. 새 XML 구조의 primary 근거는 Microsoft의 [GraphicFrame](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.presentation.graphicframe?view=openxml-3.0.1), [ShapeTree](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.presentation.shapetree?view=openxml-3.0.1), [Drawing TableCellProperties](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.drawing.tablecellproperties?view=openxml-3.0.1)이며 외부 구현 코드를 복사하지 않는다.

위 체크리스트의 미완료 구조 편집·출시 gate는 유지한다. 별도 source 글자 편집 분기는 backend·DTO·UI·Rust MCP·기존 prepared 저장에 연결했고 native capability10개는 false다. 이후 local embedded child와 owned parent를 기본 CLI에 연결했다. source plan/render/observe는 세 fresh process/profile, 동일 frozen request·후보/PDF lease·최종 raw 응답 SHA·자연 종료/handle proof를 요구한다. Windows progress 교체·일시 부재, 응답 ABA, directory 생성 identity 반례 뒤 최소 보완했다.

[확인] native/source proof를 구분하는 기존 초안 계약에 checker를 맞췄고 보존 s3의 read-only 정상·음성7개·원 proof/PDF·불변 검사 뒤 실제 default CLI native2는 inspect→no-op→한 셀 Unicode 편집→재저장4단계를 완료/exit0했다. fresh Office process10개의 자연 종료·handle/profile/PDF handoff도 통과했다. 이후 SDK의 preview 없는 읽기에서 startup 실패를 재현해 loader/owned Job poll을 보완했고 Python 전체436PASS/96.192초/exit0을 확인했다. 긴 생성 profile 경로 대조 후 앱의 자체 TEMP prefix만 줄였으며 기존 preview/lease/thumbnail24PASS·분석0과 새 실제 Rust stdio5 통합1PASS/92.371초/exit0을 확인했다. 새 source643파일 fingerprint dc2d3f7a…에서 원본 보존·한 셀 source 편집·새 immutable 판본·동일 request replay·최종 fresh read·권한/stale 거부가 통과했다. source XML·native capability 폐쇄와 기존 실패 증거를 유지한다. 다음은 새 release SDK/Windows·Android55 패키징·설치 gate다. canonical54·구조 mutation/일반 Office·새 설치·S9+/두 기기 Drive·전체 목표는 미완료다. 최신 실제 상태는 [오늘 이력](../../../_docs/history/2026-11-06.md)과 [인계](../../../HANDOFF_KO.md)를 따른다.
