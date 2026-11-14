# HWP·HWPX 원본의 문단 정렬

이 기능은 Android65(code136065)·Windows65 로컬 설치 후보에 포함됐다. [README의 APK·Windows ZIP](../README.md)에서 이 PC의 E 드라이브 파일을 연다. 태블릿에는 APK를 복사하고 Windows ZIP은 전체를 푼다. S9+·Android HWP 실행과 실제 앱 GUI 수용은 아직 확인하지 못했다.

한글 원본에서 **원본 편집**을 열고 문단 위의 **왼쪽·가운데·오른쪽·양쪽 정렬**을 선택한다. 글자와 정렬을 함께 바꾼 뒤 **저장하고 닫기**를 누른다. 정렬 도구는 보존 가능함을 확인한 문단에 표시한다. 저장 실패 시 초안을 유지하며 같은 요청을 재시도한다.

저장할 때 HWP5는 HWP5로, HWPX는 HWPX로 유지한다. 같은 스타일을 쓰는 다른 문단의 정렬을 바꾸지 않도록 원본 스타일을 비교해 재사용하거나 복제한다. 원본 판본·문단의 글자와 저장 결과를 검사하고, 기존 판본·별도 Markdown과 원본의 비수정 영역을 보존한다. 새 판본의 원본과 PDF를 기존 Office 저장 흐름에 함께 전달한다.

HWP5의 원시 스타일 기록과 HWPX의 원본 XML을 보존한다. HWPX의 알 수 없는 namespace 속성을 기본값으로 바꾸거나 전체 header를 새로 직렬화하지 않는다. 실제 문단의 알려진 배치 캐시만 갱신하며 확장 정보 안의 비슷한 이름을 가진 요소는 유지한다. 불확실한 스타일 참조나 미지원 구조에서는 저장을 중단하고 원본을 남긴다.

문단·표 셀의 글자 편집과 이 정렬 기능이 현재 연결된 범위다. 한글 원본의 이미지 삽입, 글자 범위 서식과 표 구조 편집은 계속 개발할 범위다. PDF 미리보기는 동봉한 한글 글꼴을 사용하므로 한컴 화면과 줄바꿈·모양이 다를 수 있다. 전체 Office 기능이나 모든 문서의 레이아웃 동등성을 뜻하지 않는다.

## MCP에서 사용

기존 `read_document`로 원본의 `office.sourceRevisionId`, 문단 `id`, `text`, `paragraphFormat.alignment`를 읽는다. HWP에서는 기존 `office_edit`의 `paragraphFormat` 중 아래 네 필드만 사용한다.

```json
{
  "op": "paragraphFormat",
  "id": "s0:p1",
  "expectedTextSha256": "<읽은 원문 text의 UTF-8 SHA-256>",
  "alignment": "center"
}
```

문단 ID와 digest는 실제 읽은 값으로 바꾼다. `alignment` 값은 `left`, `center`, `right`, `justify`다. 같은 batch에서 글자를 바꾸어도 digest는 batch 이전 원문을 기준으로 한다. `office_edit`의 원본 판본·요청 ID·편집 허용도 기존 계약을 따른다. 글자 스타일·목록·쪽 나눔 등의 다른 `paragraphFormat` 필드는 이 한글 경로에서 허용하지 않는다.

[build65 통합 기록](../build/validation/office-source-build65/checkpoint65.json)은 새 설치 HWP DLL의12개 원본/PDF 검사와 실제 DLL/SDK15개 검사를 결합한다. 기존 전체 Flutter2043PASS/106skip·한글 엔진 Rust35PASS·분석0은 동일 소스의 앞선 실행을 재사용했다. 새12개 PDF는 이전에 직접 검토한 합성12쪽 PDF와 바이트가 같아 기존90dpi 시각 검토만 재사용했으며 새 GUI 실행이나 일반 문서의 레이아웃 동등성 검사가 아니다.

[구현 계획](superpowers/plans/2026-11-07-hwp-paragraph-alignment.md), [엔진 조사](hwp-engine-investigation.md), [검증 기록](mvp-validation.md)에 근거와 범위를 기록한다. `build/validation/hwp-alignment1`의 source-only·미포함 설명은 build65 포장 전 당시 기록이다. 실제 Rust 빌드, 파서/FFI 검사, PDF 시각 검사, 실제 기기 수용을 구분한다.
