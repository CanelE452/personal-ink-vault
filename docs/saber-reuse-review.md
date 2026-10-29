# Saber 재사용 검토

2026-10-22. 공식 `saber-notes/saber`의 커밋 `55eec16ad6f858bc68b7c229e497c5ed44d7c5fd`(1.36.3)을 저장소 밖 임시 폴더에서 읽기 전용 조사했다. 앱 코드 통합·설치·빌드·실기기 시험은 하지 않았다.

## 판정

**[추천] Saber 전체 기반의 제한된 검증판부터 시작한다. 필기·PDF 편집기를 유지하고 고정 ID·안전한 저장·Drive 동기화를 새 경계로 만든다.** 편집기는 독립 패키지가 아니어서 일부 위젯만 추출하는 경로는 첫 선택으로 권하지 않는다. 검증 실패 시 독립 Flutter를 비교한다. 현재 판정은 소스 검토상 조건부 적합이며 제품 기반 채택 완료가 아니다.

목표는 Galaxy Tab S9+ PDF 필기 → Windows에서 필기를 보며 Markdown 정리 → Drive 자동 전달이다. 앱의 배포 이력으로 이 흐름의 성공을 대신하지 않았다.

## 소스에서 확인한 것

링크는 모두 조사 SHA에 고정했다. `[확인]`은 정적 실행 경로 추적이며 실제 실행 확인과 구분한다.

- **입력과 도구 [확인]:** 화면→페이지 좌표 변환, pen→페이지 획 삽입→history→자동 저장 경로가 있다. 지우개는 획 전체 삭제이며 부분 절단이 아니다. [입력](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/pages/editor/editor.dart#L558), [지우개](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/data/tools/eraser.dart#L24).
- **압력/손바닥 [확인]:** Flutter stylus 종류·압력을 사용하고 stylus 감지 후 손가락 그리기를 끄는 경로가 있다. 점에는 x/y/pressure가 저장된다. 이 경로에는 tilt 저장이 없다. 손바닥 접촉·버튼·필기 지연은 S9+ 실기기에서 미검증이다. [제스처](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/components/canvas/canvas_gesture_detector.dart#L421), [획](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/components/canvas/_stroke.dart#L153).
- **PDF import [확인]:** 폭 1000의 Saber 페이지에 PDF를 배경 객체로 두고 별도 획을 얹는다. 원본 PDF 바이트를 asset으로 복사하는 경로는 있지만 기존 PDF annotation 객체 편집은 아니다. 회전/CropBox 보존은 실측이 필요하다. [import](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/pages/editor/editor.dart#L1195), [PDF asset](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/components/canvas/image/pdf_editor_image.dart#L104).
- **PDF export [확인]:** 새 PDF에 배경 스크린샷과 일부 펜 벡터를 합성한다. 원본 텍스트·링크·벡터·annotation 의미 구조를 보존하는 출력으로 볼 수 없다. 보존형 PDF 출력은 별도 설계 대상이다. [export](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/pages/editor/editor_exporter.dart#L31).
- **저장 [확인]:** `.sbn2` BSON 본문과 `.sbn2.N` 첨부를 여러 파일로 쓴다. 본문만 전송하면 PDF asset이 빠진다. `.sba`는 본문과 첨부를 ZIP으로 묶는다. 기존 파일별 병렬 쓰기에 노트 세대 전체의 원자적 발행 경계는 없다. 중간 종료 손실 가능성은 [추정]이며 미재현이다. [저장](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/pages/editor/editor.dart#L914), [codec/archive](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/data/editor/editor_core_info.dart#L470).
- **ID/텍스트 [확인]:** 노트·페이지 직렬화에 요구한 고정 noteId/pageId가 없고 경로/배열 위치를 사용한다. 제목 변경은 실제 파일 이동으로 이어진다. 텍스트는 Quill Delta이므로 Markdown 원문 편집기는 추가해야 한다. [페이지](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/data/editor/page.dart#L172), [이동](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/data/file_manager/file_manager.dart#L375).
- **동기화 [확인]:** Nextcloud 로그인→WebDAV propfind/get/put 경로다. `lib`·pubspec 검색과 해당 호출 경로에 직접 Drive 공급자/Google OAuth 구현은 없다. 시각 비교(500ms 허용 차이)로 최신 파일을 선택하고 빈 원격 파일로 삭제를 전파한다. 충돌 양쪽 사본과 삭제 복원을 요구하는 MVP에 그대로 사용할 수 없다. [구현](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/data/nextcloud/saber_syncer.dart#L18), [비교](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/data/nextcloud/saber_syncer.dart#L462).
- **수명주기 [확인]:** background 예약은 Android/iOS에 한정되고 주기/초기 지연은 12시간이다. Windows 앱 종료 중 즉시 동기화된다는 근거가 아니다. [예약](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/lib/main.dart#L157).

## 재사용 경계

유지 후보는 pointer/gesture, 펜·형광펜·획 지우개·history, canvas, PDF 배경과 native codec이다. `EditorState`, `EditorCoreInfo`, `EditorPage`, 도구·painter·asset cache가 stows/FileManager/Quill/화면 상태에 걸쳐 결합돼 있다. `packages/sbn`은 스타일/enum 중심이며 전체 편집기를 제공하지 않는다.

새 구현은 `SaberInkAdapter`(완전 snapshot 캡처/재열기), `NoteRepository`(ID/리비전/로컬 발행), `DriveAuth`, `DriveRemoteStore`, `SyncCoordinator`, Windows Markdown workspace다. 기존 `stows.loggedIn`, FileManager 업로드 enqueue, 시작 동기화, 서버/로그인 UI를 새 경계에 연결해야 한다. 기존 Nextcloud 암호화도 새 Drive의 키 복구 설계로 자동 계승하지 않는다.

`.sba`는 백업 경계로 유용하지만 매 획 수정마다 전체 archive를 전송하면 큰 PDF까지 반복 업로드한다. **일상 동기화는 본문과 해시 기반 첨부를 분리하고, 완전한 리비전 manifest를 마지막에 발행하는 안**을 추천한다.

## 빌드·라이선스

[확인] pubspec 요구는 Dart `^3.13.0`, Flutter `>=3.47.0`이다. lock과 Flutter submodule(`abaf9c523780a608bd46686fd5e53740a07077f8`)이 있다. Windows workflow는 permission_handler 제거 사전 패치를 사용하고, Android Gradle은 debug에도 release signing config를 참조한다. 그대로 복사해 SDK/개발 키가 있다고 가정하면 안 된다. [pubspec](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/pubspec.yaml), [Windows](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/.github/workflows/windows.yml), [Android](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/android/app/build.gradle.kts).

[확인] 루트는 GPL v3, onyxsdk_pen은 BSD 3-Clause, 일부 폰트는 OFL이다. 전체 전이 의존성/자산/네이티브 바이너리 배포 조건 검토는 미완료다. 통합 시 출처·수정·고지·소스 제공 방식을 기록하고 이름/아이콘/앱 ID/서명/서비스 설정을 독립시킨다. 이번에는 코드를 도입하거나 프로젝트 라이선스를 바꾸지 않았다. [루트 라이선스](https://github.com/saber-notes/saber/blob/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd/LICENSE.md).

## 검증판 통과/중단 기준

1. S9+ 실제 펜에서 압력·손바닥·버튼·두 손가락 줌·undo/redo·재열기를 기록한다. 펜 모델·OS 버전은 아직 미확인이다.
2. 회전 0/90/180/270도·CropBox·혼합 크기의 합성 PDF로 Android 저장→Windows 표시의 위치와 원본 해시를 비교한다.
3. 제목/페이지 순서 변경 뒤 ID 유지, 저장 도중 종료 후 직전 완전 리비전 복구를 검증한다.
4. PDF 재업로드 없이 작은 획 변경을 전달하고, 중단 재시도·동시 수정·삭제 충돌·빈 기기 복원을 확인한다.

핵심 손실/좌표 오류가 두 차례 원인별 수정·재검증 후에도 남거나, 저장 경계를 붙이기 위해 입력/PDF 코어 전면 재작성이 필요하면 fork 경로를 중단하고 독립 Flutter와 비용을 비교한다. 실제 결과 전에는 재사용 성공으로 표시하지 않는다. 후속: [설계](mvp-design.md), [개발 계획](roadmap.md).
