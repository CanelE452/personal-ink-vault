# Word 사진 추가·이동·삭제 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Root executes all tests, formatting, native processes and builds. Workers change only their assigned files after root observes RED.

**Goal:** Windows DOCX의 검증 가능한 본문 AS_CHARACTER 사진에 실제 추가·이동·삭제를 제공하고, 같은 계약을 Flutter 편집기와 기존 MCP `office_edit`에 연결한다.

**Architecture:** source-bound 사진 목록과 예상 변경 ledger가 허용한 Frame token·native inventory 변화만 검증한다. 이동은 원본 payload/속성/PropertyState로 새 native 객체를 만들고 정확한 target Frame을 확인한 뒤 기존 객체를 제거하는 방식이다. 저장·재열기 검증과 기존 불변 원본/PDF/edition 공개 경로를 통과한 결과만 저장 성공으로 처리한다.

**Tech Stack:** 기존 Windows LibreOffice UNO/Python, Flutter/Dart, ink_vault_core의 prepared commit, Rust `ink_vault_mcp` typed schema. 새로운 엔진·서비스·패키지는 도입하지 않는다.

**Spec:** [요구사항](../../requirements.md), [엔진 조사와 native 근거](../../office-engine-investigation.md), [Android interaction 계획](2026-11-04-android-office-interaction.md). 아래 task 체크리스트는11월4일의 실행 계획을 보존한다. 현재53 소스 구현·최종 gate 상태는 마지막 절이 우선하며, build52를 새 기능 설치 묶음으로 표시하지 않는다.

## Global Constraints

- 원본 revision/파일과 기존 source IDs를 보존한다. 편집은 소유 working copy에서 수행하고, 새 원본·PDF·binding은 기존 edition writer로 새 불변 판본에 등록한다.
- 본문 문자열 전체 대입으로 사진을 옮기거나 보호 객체를 재구성하지 않는다. 공개 오프셋은 UTF-16이며 Writer native cursor는 기존 `office_text.selection(..., paragraph=True, scalar_cursor=True)`의 실제 prefix 검증을 사용한다.
- 이미지 이름·해시·collection 순서는 native 정체성이나 owner의 근거가 아니다. 같은 payload/크기의 다른 사진도 구분해야 한다.
- 기존 `imageReplace`, PPT `imageAdd`/도형 작업, Word text/layout, undo/redo, preview readonly, MCP 권한·영수증·동일 판본 재시도, Android journal과 자료 형식을 보존한다.
- PNG/JPEG의 기존 20MiB/40M pixels, batch 80MiB 제한과 원본 revision에 묶인 sealed asset 경로를 재사용한다. 임의 경로·URL 입력, 새 의존성, 기존 timeout/watchdog/FIFO 변경은 하지 않는다.
- 모든 실행은 root가 직렬 소유한다. native 세 작업을 동시에 실행하지 않는다. 다른 사용자의 Office/임시 폴더를 종료·삭제하거나 retained profile을 추정해 지우지 않는다.
- 각 task는 시험 작성 → root의 실제 RED → 최소 제품 변경 → root GREEN·리뷰 순서다. commit/push/게시와 전역 설정 변경은 하지 않는다.

## 확인한 연구와 한계

[확인] ignored `build/validation/office-word-fidelity/picture-mutations-probe2`~`probe5`는 root가 실제 실행했다. 모두 terminal0·`completed/integrityConfirmed/ownedClosuresConfirmed=true`이고 cleanupErrors가 없다. terminal0은 관측 완료·소유 종료를 뜻하며 모든 후보의 성공을 뜻하지 않는다.

- probe2(70.614초): `insert`와 마지막 사진의 `remove`는 live/독립 재열기 intent=true다. 동일 AS_CHARACTER 객체의 `.attach()`는 `SwXFrame::attach(): re-anchoring AS_CHAR not supported`로 거부됐다.
- probe3(68.145초): 같은 객체의 재삽입도 위 native 예외다. remove→재삽입은 호출이 반환됐지만 old native 정체성·목표 Frame 검증을 통과하지 않았다. 생성 descriptor 참조를 실제 삽입 객체로 간주한 첫 clone도 실패했다. 실제 snapshot에는 ORIGINAL/MOVE의 두 Frame이 있었으므로 이를 삽입 부재의 근거로 해석하지 않는다.
- probe4(34.275초): 유일한 native inventory delta로 새 실제 객체를 결합해 두 Frame을 검증했다. old descriptor는 actual object와 달랐으며, strict clone은 공존 중 ZOrder 0→1과 DEFAULT→DIRECT PropertyState 차이를 그대로 실패로 남겼다.
- probe5(34.886초): 별도 `clone-move-deferred-order`만 공존 중 ZOrder 차이를 허용하고 source DEFAULT에는 실제 `setPropertyToDefault`, DIRECT에는 캡처 native 값을 적용했다. 원본 제거 뒤 ZOrder와 모든 raw IMAGE_PROPERTIES/PropertyState가 정확히 같았고, live·독립 재열기 delta는 둘 다 `[]`, intent=true다. 원본 native 참조는 사라지고 검증한 새 참조 하나가 남았다. descriptor≠actual을 계속 기록했다.

표본은 합성 DOCX 한 종류, PNG 한 장(37×29/103bytes), 본문 AS_CHARACTER 원본 2540×1905Hmm이다. 제목·Unicode/emoji/결합 문자 문단·표·머리말·꼬리말 텍스트가 보존됐다. 새 사진은 본문에서만 조작했으며, 다른 owner·모든 run/section/layout·JPEG/EXIF·실제 Word/Android 왕복·제품 기능 전체를 입증하지 않는다. probe5의 네 owned server/loader/job/관측 핸들은 닫혔지만 세 profile은 retained다. profile 제거 성공으로 세지 않는다.

정확한 연구 영수증과 SHA는 조사 문서의 해당 절을 따른다. 합성 canonical은 실행마다 새로 만들었으므로 서로 다른 실행의 DOCX SHA가 다른 것을 변조로 해석하지 않는다. 각 실행 내부 원본/working input/saved reopen hash와 좁힌 source/runtime fingerprint는 불변이었다.

## Review Focus

1. 사진0장 초기 문서와 마지막 사진 삭제: `[]`는 검증한 빈 목록이고 `null`은 unknown이다. 빈 source binding을 지원하도록 task1/3에서 검증한다.
2. 같은 payload/크기의 여러 사진과 중복 문단: 잘못된 사진·위치를 고르지 않고 생존 객체의 서식/상대 순서를 보존한다. task2/3의 actual native delta·복수 사진 시험으로 고정한다.
3. surrogate 중간·field/bookmark/Frame·보호 section 및 owner 혼동: target을 변경 전에 거부한다. task1/2에서 prefix·보호 경계와 actual owner를 검증한다.
4. undo/redo→미리보기→다른 편집/저장 및 늦은 응답: logical alias·asset·작업 순서를 보존하고 이전 preview가 현재 draft를 덮지 않는다. task4에서 고정한다.
5. MCP 권한/판본 변경·공개 후 응답 유실: 중복 edition/다른 source 수정 없이 정확한 prepared 판본을 재확인한다. task5에서 기존 writer 계약과 함께 고정한다.

---

## 작업 계약

다음 closed operations를53 소스에 구현했다. 기존 PPT용 좌표 `imageAdd`의 의미는 유지한다. 실제 설치 묶음의 승격 상태는 최종 gate 기록을 따른다.

```json
{"op":"wordImageAdd","id":"new-batch-alias","ownerId":"body","paragraphId":"paragraph-id","offsetUtf16":0,"expectedTextSha256":"64-lowercase-hex","assetId":"sealed-asset-id","width":25.4,"height":19.05}
{"op":"wordImageMove","id":"source-or-batch-image-id","ownerId":"body","paragraphId":"paragraph-id","offsetUtf16":0,"expectedTextSha256":"64-lowercase-hex"}
{"op":"wordImageDelete","id":"source-or-batch-image-id"}
```

- `width/height`는 mm, 양수·유한·소수 둘째 자리까지·최대1000mm로 검증한다. move는 원래 크기·crop·native margins·속성과 PropertyState를 보존하며 asset을 다시 받지 않는다.
- `id`는 add의 미사용 batch alias다. move는 같은 logical ID를 검증한 새 native ref에 결합하고 delete는 ID를 retired로 남겨 같은 batch에서 재사용하지 못한다. 저장 후 재검사한 새 revision의 IDs를 사용한다. 이전 revision ID를 이름/해시로 복구하지 않는다.
- 첫 제품 범위는 native 검증을 통과한 본문 문단의 AS_CHARACTER다. header/footer·표 셀·text frame·AT_CHARACTER·그룹·OLE·unsupported anchor/format은 기존 replace 지원과 별도로 새 move/add target capability를 false로 둔다. 확대는 owner별 새 native RED/GREEN 뒤 진행한다.
- target은 실제 본문 owner+문단 native ref, 현재 paragraph text SHA, UTF-16 경계와 protectedRanges를 모두 확인한다. zero-width Frame과 같은 공개 offset, field/bookmark 경계, 원래 anchor와 구분되지 않는 같은 위치는 추정하지 않고 변경 전에 거부한다. before/after affinity 확대는 별도 계약이다.
- snapshot에 optional `wordImageTargets`를 추가한다. `null`은 unknown, `[]`는 검증했으나 가능한 target이 없음이다. 각 row는 `{ownerId, paragraphId, canAdd, canMoveHere}`이며 기존 paragraph text details의 SHA/UTF-16/protectedRanges와 함께 사용한다. `wordImages` row에는 `canMove/canDelete`와 nullable `offsetUtf16`을 추가한다. 검증한 AS_CHARACTER Frame의 정확한 문단 내 위치만 제공하며 unknown 위치/누락 capability는 mutation false다. 사진0장도 target을 표시할 수 있어야 한다.
- source-bound 예상 ledger는 added/retired/rebound logical ID, actual old/new native refs, 원래/목표 Frame token과 각 이미지의 payload/raw format/state를 가진다. 허용 변화는 요청에서 계산한다. live snapshot을 읽은 뒤 전체 expected state를 새 정답으로 대체하지 않는다.

## Task 1: 빈 목록·위치 capability와 예상 inventory 계약

**Files:** Modify `windows/office_engine/office_word_images.py`, `windows/office_engine/office_word_objects.py`, `windows/office_engine/office_word_layout.py`, `windows/office_engine/office_word_fidelity.py`, `windows/office_engine/office_worker.py`; extend `windows/office_engine/test_word_image_catalog.py`, `windows/office_engine/test_word_images.py`; create `windows/office_engine/test_word_image_mutations.py`.

**Interfaces:** `WordImages.snapshot_targets() -> list | None`; `WordImages.snapshot()`의 `canMove/canDelete`; `WordImages.verify_source(bindings)`는 기본적으로 원래 inventory를 엄격히 보존하고 승인된 pending ledger delta만 수용한다. 빈 검증 원본은 `source_bindings=[]`다.

- [ ] `test_verified_empty_source_has_add_targets`, `test_null_catalog_is_not_empty_capability`, `test_frame_owner_or_inventory_gap_disables_mutations`를 작성한다. 0장/unknown 구분, body target만 true, 누락·중복 actual Frame/외부 owner/OLE면 false를 검사한다.
- [ ] root가 `python -B -m unittest discover -s windows/office_engine -p test_word_image_mutations.py`의 API 부재/동작 실패 RED를 확인한다.
- [ ] 빈 inventory 검증과 target 계산을 구현한다. `WordObjectRegistry.verify_complete()`를 우회하거나 실패한 source catalog를 자동으로 신뢰하지 않는다. ledger 없이 count/owner/format/payload가 변하면 기존 거부를 유지한다.
- [ ] root가 새 시험과 기존 `test_word_image_catalog.py`, `test_word_images.py`, `test_word_fidelity.py`를 실행한다. 기존 replace의 불변 inventory/owner/anchor 거부가 그대로 통과해야 한다.

## Task 2: native 추가·삭제·객체 교체 이동

**Files:** Create `windows/office_engine/office_word_image_mutations.py`; modify `windows/office_engine/office_word_images.py`, `windows/office_engine/office_worker.py`; extend `windows/office_engine/test_word_image_mutations.py`, `windows/office_engine/test_word_image_worker.py`.

**Interfaces:** `WordImages.add(operation, asset)`, `WordImages.move(operation)`, `WordImages.delete(operation)`가 closed operation을 받아 검증 후 ledger/ID binding을 갱신한다. native 상세 구현은 새 모듈의 `add(catalog, operation, asset)`, `move(catalog, operation)`, `delete(catalog, operation)`에 둔다. 같은 모듈의 `raw_image_state(image) -> dict`는 모든 IMAGE_PROPERTIES의 presence/type/attributes/native value/PropertyState를 보존해 ledger에 결합한다. Python worker의 `kind == 'word'` 분기만 새 세 op를 dispatch한다.

- [ ] unit RED: add→move→replace→delete의 새 alias, ID 재사용/retired ID 거부, zero/last image, 동일 SHA 두 사진, duplicate paragraph text, descriptor≠actual, delta0/2·old ref 유실, scalar/UTF-16 prefix 불일치, surrogate 중간·보호 토큰·다른 owner 거부를 작성한다.
- [ ] root RED 후 native 변경을 구현한다. add는 실제 새 Graphic→AS_CHARACTER→target 삽입→유일한 actual inventory delta/Frame 검증, delete는 지정 actual binding만 `removeTextContent`, move는 probe5의 새 객체→actual target Frame 검증→old 제거 순서다. 실패하면 전체 private 작업을 폐기하며 역연산으로 원본을 대충 복구하지 않는다.
- [ ] source DEFAULT는 검증한 native `setPropertyToDefault`, DIRECT는 실제 native 값으로 복사한다. void/없는 속성/readonly/unknown state를 임의 enum이나 기본값으로 대체하지 않는다. `test_default_state_api_failure_never_retires_original`과 `test_final_raw_state_drift_is_rejected`를 root RED/GREEN으로 고정한다.
- 실제 후속 native 연구에서 Title/Description은 DEFAULT state이면서 authored 값이 비어 있지 않았다. DEFAULT API 호출 뒤 presence/type/attributes/state는 같고 value만 다르면 **캡처한 source native 값**을 복원하고 즉시 전체 raw 값·상태의 정확한 일치를 요구한다. setter가 DIRECT로 바꾸거나 실패하면 거부한다. authored 값을 API default 값과 같은 것으로 간주하지 않는다.
- 두 actual 이미지가 공존할 때 XNamed 이름 중복은 native에서 거부됐다. 생성 descriptor에는 Graphic/AnchorType/크기/margins만 먼저 설정하고, 실제 삽입 객체를 결합한 뒤 나머지를 복원한다. source old 객체의 이름·metadata는 그대로 검증한다. 새 객체의 native 임시 XNamed와 실제 존재하는 Name.value만 공존 기대값에 한정해 담으며 정체성 근거로 사용하지 않는다. old 제거 후 캡처한 원래 이름을 복원하고 최종 전체 raw/state 일치를 요구한다. 실제 없는 Name property는 만들지 않는다.
- [ ] 새 raw-state sidecar는 기존 `image_properties()`의 computed-position semantic 비교와 별도로 검사한다. 기존 replace/layout 정규화 계약을 바꾸거나 새 raw 검사에서 해당 필드를 빼지 않는다. ignored probe/helper는 실행 근거로만 사용하고 제품 runtime에서 `build/validation` 모듈을 import하지 않는다.
- [ ] 공존 중 ZOrder 차이와 최종 live/reopen 단계의 예상 map을 구분한다. live add는 append, delete는 삭제 index 압축이고, saved/reopen은 변경 전 native Frame 순서와 요청한 target에서 계산한 최종 Frame 순위다. 이동 후 원래 수치 ZOrder가 항상 같아야 한다는 단일 이미지 가정을 복수 사진에 적용하지 않는다. 모든 raw format/state와 예상 단계별 ZOrder를 정확히 비교하며 final ZOrder 필드를 비교에서 빼지 않는다.
- [ ] root가 새 unit/worker 시험과 기존 imageReplace 시험을 실행한다. 새 op는 expectedSourceSha256가 정확한 DOCX만 받고 PPT/DOC/ODT에는 들어가지 않아야 한다.

## Task 3: 예상 token·export·독립 재열기 수용

**Files:** Modify `windows/office_engine/office_word_fidelity.py`, `windows/office_engine/office_word_inline.py`, `windows/office_engine/office_word_export.py`, `windows/office_engine/office_word_layout.py`, `windows/office_engine/office_worker.py`; extend `windows/office_engine/test_word_image_save.py`, `windows/office_engine/test_word_inline.py`, `windows/office_engine/test_word_export.py`; create `windows/office_engine/test_word_image_mutations_native.py`.

**Interfaces:** 최종 ledger가 예상 body/owner Frame token을 제공하고 `verification_state()/verify_reopened(expected)`가 그 예상과 비교한다. `export_bindings`는 살아 있는 최종 actual refs만 담는다. 사진0장·마지막 삭제도 새 저장 검증을 끄지 않는다.

구현 시 semantic `verification_state()`의 기존 반환은 유지한다. 별도 `reopen_verification_state()`가 검증된 mutation ledger의 `semantic`·`imageRawStates` envelope를 반환하고, fresh `verify_reopened()`가 catalog 생성 전에도 full native registry와 raw sidecar를 확인한다. 빈 최종 목록도 명시적 envelope에 포함한다.

- [ ] RED: 마지막 삭제 뒤 빈 bindings·빈 inline marker 경로도 재열기 필수, add/delete/move 뒤 평범한 글자 저장도 사진 검증 유지, source에 없는 generated marker/duplicate marker/retired ref가 export에 남으면 거부한다. marker와 DOCX XML을 고쳐 잘못된 native binding을 숨기는 경로를 허용하지 않는다.
- [ ] root RED 후 pending token delta→actual 검증→ledger commit을 연결한다. field/bookmark/runs·제목·표·header/footer·style usage의 기존 보존을 유지하고 최종 사진/owner 목록만 요청의 정확한 변화와 비교한다.
- [ ] 새 native `--case basic`은 0→1 add, 1→0 delete, probe5형 move, 이어지는 text/replace와 재저장을 검사한다. `--case multiple`은 서로 다른 사진3장·같은 payload2장·중복/빈 문단·앞뒤 이동·같은 문단의 다른 안전 위치·중간/마지막 삭제와 정확한 survivor/ZOrder map을 검사한다.
- [ ] `--case protected`는 emoji/combining/surrogate 중간, 실제 PAGE field/bookmark/보호 section, zero-width Frame 접점, header/footer·표·AT_CHARACTER 요청을 변경 전 거부한다. `--case failure`는 setter/default API·delta·최종 raw state/재열기 drift에 저장 결과/edition이 없고 source SHA가 같은지 검사한다.
- [ ] root가 각 group을 기존 owned job/시간 한도 안에서 순차 실행한다. 예: `& "$Runtime/program/python.exe" -I -B windows/office_engine/test_word_image_mutations_native.py --runtime "$Runtime" --output build/validation/office-word-fidelity/mutations-native-basic1 --case basic`. 그룹이 커지면 분리하고 기존 timeout을 늘리지 않는다. 제품 run_request 종료 뒤 별도 owned server로 저장 DOCX를 다시 열어 Frame/range/raw state·XML/media/PDF를 검사한다.
- [ ] 여러 이미지에서 최종 raw 계약을 입증하지 못하면 그 경우 capability를 false로 유지하고 실패를 기록한다. 단일 합성 성공으로 전체 문서 지원을 활성화하지 않는다.

## Task 4: Dart 계약·Word draft·undo/redo·UI

**Files:** Modify `lib/data/office/windows_office_engine.dart`, `lib/pages/office/windows_word_editor.dart`, `lib/pages/office/windows_office_editor.dart`; extend `test/office/windows_word_image_test.dart`, `test/office/windows_word_image_editor_test.dart`, `test/office/windows_office_editor_test.dart`.

**Interfaces:** `WindowsOfficeOperation.wordImageAdd/wordImageMove/wordImageDelete`는 위 wire 필드와 같은 named arguments를 사용한다. `WindowsOfficeSnapshot.wordImageTargets` 및 `WindowsOfficeWordImage.canMove/canDelete`는 누락/unknown을 비활성으로 읽는다. `_WordCheckpoint`는 사진 목록·target 상태·logical alias/asset·전체 journal을 복원한다.

- [ ] root RED: 사진0장에도 추가 버튼, add→move→delete undo/redo의 순서·logical alias·asset 복원, 안전 target 선택과 지원하지 않는 owner/보호 범위 비활성, 320px layout을 작성한다. 사진 교체의 기존 시험을 유지한다.
- [ ] DTO와 `_WordDocumentDraft`의 add/move/delete를 구현한다. add alias를 한 번만 할당하고 `_verifyImages`는 기대 ledger의 정확한 ID/owner/target/수량 변화만 허용한다. 현재의 같은 수량/같은 위치 검사만 지우지 않는다. asset은 undo/redo에서 참조하는 동안 보존하고 preview/commit에는 해당 journal이 쓰는 sealed asset만 전달한다.
- [ ] root RED: 늦은 preview→새 편집/undo·새 source/root/note 전환, 미리보기 검증 실패, 저장 실패/재시도·재열기, asset picker 취소/중복 결과를 작성한다. 실패 시 draft를 보존하고 성공 전 원본 저장 notice를 내지 않는다.
- [ ] root GREEN: `flutter test test/office/windows_word_image_test.dart test/office/windows_word_image_editor_test.dart test/office/windows_office_editor_test.dart`와 실제 저장 후 UI 재열기를 확인한다. preview는 새 edition을 쓰지 않고 저장은 기존 `OfficeDocumentStore.prepareEdited/commitPreparedEdition` 경로를 재사용한다. Android native editor의 사진 UI를 이 Windows capability로 가리지 않는다.

## Task 5: MCP·Rust typed operation 연결

**Files:** Modify `lib/data/mcp/vault_mcp_service.dart`, `lib/data/office/windows_office_engine.dart`, `packages/ink_vault_mcp/src/server.rs`; extend `test/mcp/office_word_image_test.dart`, `test/mcp/access_permission_race_test.dart`, `packages/ink_vault_mcp/tests/stdio.rs`; update `packages/ink_vault_mcp/README.md`의 도구 설명.

**Interfaces:** 기존 `office_edit`의 세 closed variants와 `read_document`의 target/사진 capability만 추가한다. Rust `OfficeOperation::{WordImageAdd, WordImageMove, WordImageDelete}`는 위 camelCase JSON과 같고 `deny_unknown_fields`를 유지한다. 새 tool이나 별도 write 우회는 만들지 않는다.

- [ ] root RED: 정확한 세 DTO 전달, owner/offset/hash/dimensions 타입·누락·unknown field·URL/path·다른 source의 asset 거부, `null`/빈/100행 초과 truncation과 unknown capability를 작성한다. 기존 PPT `imageAdd` JSON은 바뀌지 않아야 한다.
- [ ] root RED 후 parser/render/SDK schema와 Word용 asset staging의 `wordImageAdd` 포함을 연결한다. move/delete는 업로드 asset을 요구하지 않는다. read-only 도구가 업로드/edition을 쓰지 않게 한다.
- [ ] 실제 sourceRevisionId/expectedRevisionId·requestId·operation body·sealed asset binding을 영수증에 묶는다. 현재 일반 office_edit은 started→completed이며 공개 직후 completed 기록이 유실되면 operation_state_unknown을 반환한다. 이를 이미 재개 가능한 계약으로 취급하지 않는다. 새 Office 전용 prepared 영수증은 공개 전에 정확한 descriptor/recovery files를 보존하고 resumePreparedEdition/commitPreparedEdition으로 같은 준비 판본을 재확인한다. metadata/source 변경 및 최종 publish 직전 write 권한 취소는 거부한다. 새 source의 alias로 자동 재연결하지 않는다.
- [ ] root가 `flutter test test/mcp/office_word_image_test.dart test/mcp/access_permission_race_test.dart`, `cargo test --manifest-path packages/ink_vault_mcp/Cargo.toml`와 실제 stdio→앱→native→edition→재열기를 실행한다. discovery tool 수와 기존 imageReplace/PPT/페이지 이력 동작을 유지한다.

## Task 6: 최종 수용과 공개 범위 기록

**Files:** Update `docs/mvp-validation.md`, `docs/office-engine-investigation.md`, `HANDOFF_KO.md`, `_docs/history/2026-11-04.md` 또는 실제 실행일 기록. Root owns this gate.

- [ ] 변경 소스 고정 후 fresh review가 빈 inventory, 동일 payload, protected target, retained asset/undo, retired ref, 최종 manifest 권한/재시도를 검토한다. root가 발견한 결함은 실제 RED부터 고친다.
- [ ] root가 필요한 전체 Flutter/core/SDK·분석·source-bound native groups를 실행하고, 그 뒤 Windows/Android 묶음과 설치된 실제 MCP/Word 저장·재열기를 검사한다. 기존 본문 편집·페이지 geometry·payload replacement·PDF 필기를 포함한다. 겹치는 시험 수를 합산하지 않는다.
- [ ] 실제 결과와 SHA·owned 종료·retained profile을 함께 기록한다. source fingerprint 변경 시 이전 native 근거를 자동 재사용하지 않고 source bytes와 원래 evidence SHA를 대조한다.
- [ ] 대상 기능·문서 범위를 명시한 뒤에만 새 capability/묶음을 승격한다. Microsoft Word/Android S9+/S Pen·두 기기 Drive·전체 Office fidelity가 별도 미검증이면 그대로 남긴다. 이 계획 작성과 probe5를 제품 구현 완료나 build52 기능으로 표시하지 않는다.

## 남은 위험과 확대 순서

- [확인/범위 제한] 동일 PNG 세 actual Frame의 live/독립 재열기 ZOrder·상대 순서·기존 사진 이동/정확한 삭제는 최종 multiple3로 확인했다. 이를 다른 anchor/owner/모든 문서로 확대하지 않는다.
- [미확인] JPEG/EXIF·crop/rotation·nonzero native margins·투명도/배경·relative sizing 및 readonly/default-state 조합. 기존 replace의 보존 범위도 새 mutation의 증거로 대신하지 않는다.
- [미확인] header/footer variants·표 cell·text frame·floating anchor·section·복잡한 field/bookmark 접점의 새 삽입/이동. 첫 범위를 지나치게 넓히지 않고 owner별 시험을 추가한다.
- [확인/범위 제한] 제품 worker의 실제5그룹과 Rust stdio→앱→native→immutable edition은 최종 소스로 확인했다. 기존 probe는 제품 연결 이전 연구로 보존한다. 새 설치 묶음 승격과 실제 기기 수용은 별도 gate다.
- [미확인] 실제 Microsoft Word/Android 원본 표시·편집·저장 왕복과 개인 문서 수용. synthetic DOCX/PDF의 성공만으로 일반 fidelity를 주장하지 않는다.

## 현재 진행과 추가 native 계약

[확인] Task1은 실제 RED 뒤 verified-empty 목록·본문 target·native prefix offset을 구현했고 root의 Word 회귀151개가 통과했다. DTO14개와 Rust 전체26개(bridge12/stdio14)도 통과했다. UI 새8개는 RED, 기존 replace3개는 PASS다. backend 확장 RED는20개 중1fail/33error subcases이고 worker5개도 새 dispatch/preflight에서 실패했다. 이를 구현 완료로 표시하지 않으며 APK/ZIP은 build52 그대로다.

[확인] source 사진3장의 inventory/no-op는 서로 다른 payload와 동일 payload 모두 실제 Frame binding·raw state·독립 재열기를 통과했다. 중간 사진1개만 삭제한 결과도 통과했다. V1 add 두 실행은 live는 맞지만 저장·재열기 후 ZOrder 및 새 객체15필드의 DEFAULT→DIRECT 차이를 실패로 남겼다.

V2는 새 actual 객체에 캡처한 native 값을15필드 그대로 재설정하고 요청 Frame 순위로 저장 기대값을 계산했다. live/독립 재열기 raw delta는 모두 빈 목록이었으나 BackColor/BackTransparent의 **자기 setter 직후** state가 DEFAULT였기에 후보는 실패다. 다른 setter를 마친 후에는15필드 모두 DIRECT였다. V3는 이를 별도 유한 batch 계약으로 정의했다. 모든 setter의 반환·값·native 정체성을 검사하고, batch 최종15필드의 값·DIRECT state 및 나머지 모든 raw 필드가 정확히 같아야 한다. 중간 state를 지우거나 source의 상태를 정규화하지 않는다. V2 실패 근거도 보존했다.

[확인] V3의 앞쪽 동일 사진 사례47.596초와 중간 서로 다른 사진 사례47.163초는 completed/integrity/ownedClosures/allRequestedIntents=true, cleanupErrors=[]다. source refs·payload·native Frame·authored 내용·raw 값/상태·metadata와 독립 재열기·source bytes를 확인했다. 해당 synthetic 새 객체의15필드에만 적용하는 계약이며 authored metadata가 비어 있던 이 fixture가 nonempty metadata clone이나 일반 Word fidelity를 입증하지 않는다. 제품 add/move/delete·UI·MCP·prepared 판본의 native 수용은 다음 gate다.

### 11월5일 제품 gate 진행

[확인] 실제 worker basic4는178.582초에 사진0→add→move→delete·정확한 마지막 빈 목록·같은 문단 offset1/8 각각 이동·같은 alias batch 최종 빈 목록을 통과했다. multiple2는169.398초에 동일 PNG 세 actual Frame·nonempty Title/Description/HyperLinkURL을 확인하고 새 사진 add/move/delete의 정확한 source 복원, 기존 첫 사진의 다른 문단 이동, 같은 payload 가운데 원본만 삭제까지 모든 raw·Frame·source SHA·독립 재열기를 통과했다. source/runtime/helper subset fingerprint와 owned 독립 handle 종료를 확인했다. 이들은 일반 문서·모든 run/anchor/format·기기 수용의 증거가 아니다.

후속 fresh review는 첫 mutation 전 metadata drift가 `activate()`의 새 기대값으로 채택될 수 있음을 지적했다. root가29개 시험의25개 failing subcase를 확인한 뒤 initial immutable authored metadata/XNamed와 actual refs/count를 비교하도록 수정했다. ordinary text/geometry의 computed Hori/Vert 위치 정규화는 유지했다. initial raw evidence가 None이면 나중에 재신뢰하지 않으며 source0의 검증한 []는 지원한다. 수정 후 전체 Python185개가 PASS다. 이 마지막 guard 뒤 최종 source를 고정해 basic5/multiple3·protected/preflight·실제 fault injection·SDK/App/native 전체 경로를 새로 검증 중이다.

[확인] Dart Office/MCP 회귀546PASS/3skip/0FAIL(149초), UI 집중34PASS, Rust26PASS다. 새 MCP 영수증의 actual rename-loss/full restart/manifest 손상/권한·source 경합25개와 closed Word parser·metadata34개는59PASS다. 독립 검토에서 v2→version1 단일 변경 우회와 linked revisions parent 우회를 실제 RED로 재현해 닫힌 legacy shape와 부모 nofollow 검사를 추가했다. 구형 v1·optional startedAt 호환은 유지한다. source와 tests를 style 정리한 최종 분석은 문제0이다. 전체 앱 회귀·실제 stdio→native→edition·설치 묶음 빌드/검증은 아직 진행 중이며 build52 APK/ZIP은 유지한다.

### 11월5일 최종 소스 gate와 build53 준비

이 절이 위 중간 진행 기록보다 우선한다. [확인] Task1–5의 source 구현·DTO/UI·closed MCP/Rust schema·prepared 영수증은 실제 RED→GREEN 뒤 연결했다. 최종 Python185PASS, Rust26PASS, 최신 Office/MCP80PASS, 전체 Flutter1,218PASS/108skip/0FAIL(5분25초/exit0), 분석 문제0(7.1초)다. 겹치는 시험을 합산하지 않는다.

최종 source 고정 뒤 native basic5(181.207888초), multiple3(158.296958초), protected1(104.590484초), preflight1(66.935865초), failure1(67.759726초) 모두 완료·무결성·소유 독립 handle 종료를 확인했다. source0/마지막 삭제·같은 문단 위치·동일 PNG 세 actual Frame·nonempty authored metadata·기존 사진 이동·정확한 삭제·UTF-16/보호 위치·source SHA를 포함한다. failure1은 실제 native 변경 뒤 명시적인4종 in-memory fault injection과 원래 guard의 거부·private edited/PDF 제거다. retained profile 삭제 성공이나 자연 발생 장애로 확대하지 않는다.

실제 Rust stdio→앱→native Word 사진0→1→1→0은1PASS/0skip/약67초, native3회·같은 요청 재시도·원본 bytes와 binding 보존을 확인했다. 공개 계약은 MCP16도구·Office28작업, Word `wordImageAdd/Move/Delete`다. prepared/completed 영수증은 같은 인자로 고정 계획/files/판본을 재확인하고 native 작업을 중복 실행하지 않는다. started 이전/전원 손실 전반의 exactly-once를 보장하지 않는다.

실제 product 실행에서 발견한 예외는 원래 source 상태를 약화하지 않고 닫았다. descriptor FrameStyleName은 attachment 전에 읽지 않고 실제 삽입 객체에 전체 속성을 복원한다. 두 객체 공존 중에는 새 객체의 임시 XNamed/Name **값만** 허용한 기대값으로 검사하고 원래 객체를 제거한 뒤 원래 이름 전체 상태를 복원한다. source 이름은 건드리지 않으며 실제 없는 Name property를 생성하지 않는다. 이 공존 예외는 ZOrder와 별도로 명시한 유일한 임시 이름 변화다. DEFAULT Title/Description의 nonempty 값을 잃는 경우 실제 default API 후 presence/type/attributes/state가 정확하고 값만 다를 때만 캡처한 native 값을 설정하며 최종 전체 raw/state 일치를 요구한다. 초기 source authored metadata/XNamed drift는 첫 mutation 전에 거부한다. 기존 일반 text/geometry computed-position 계약은 유지한다.

첫 전체 Flutter는 Android 재시도1건10분 timeout·3건 미완료를 남겼다. 진단5종과 원본 파일3회·전체 재실행은 통과했지만 원인은 미확정이다. 원본 시험/제품 queue·timeout을 바꾸지 않았고 최초 실패를 보존한다. 재실행 통과를 버그 수정으로 기록하지 않는다.

[확인] Windows53 Release218.8초·Android136053 ARM64 debug110.0초 모두 빌드 exit0이다. 빌드/최종 검증 전후612개 source SHA는 `8b834d72f79d90d18a1b6697090d9bae17f63ac79693d1de194ba7a8bcfd4ecc`로 같다. 새 설치 폴더의 실제 MCP/문서 엔진19PASS/0skip/0FAIL(2분46초), DLL FFI9PASS/0skip/0FAIL(1초), helper46/native3·최종 독립45개 검사를 확인했다. **Task6의 이번53 synthetic 범위 패키지 무결성·canonical APK/ZIP 승격을 완료했다.** ZIP19,696파일/1,626,006,811unpacked bytes의 모든 member SHA/CRC와 APK 서명을 검사했으며 이전 build52 묶음은 보존한다. 실제 S9+/S Pen·두 기기 Drive·외부 LLM 앱 등록·일반 Office fidelity와 전체 프로젝트 목표는 미완료다. 최종 파일/해시는 [검증 기록](../../mvp-validation.md)을 따른다. 원래 task 체크리스트는 광범위한 계획 기록이므로 검증하지 않은 확대 사례까지 완료로 표시하지 않는다.
