# Rnote 공개 소스 참조와 무한 필기 구현의 경계

2026-10-30. 사용자가 StarNote 본체를 충분히 참조할 수 없으면 다른 비슷한 앱을 참고해 구현하도록 허용했다. 무한 필기·카메라·입력 상태의 추가 참조로 [Rnote 공개 저장소](https://github.com/flxzt/rnote/tree/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe)를 읽었다. 고정 커밋은 `6bbc9b201adb0ab264f20dcdf6f23a18908eedfe`다.

**범위:** 공식 공개 소스의 지정 파일과 함수 몸체를 HTTP로 읽은 소스 수준 참조다. Rnote 배포 파일에 REA를 수행하거나 Rnote를 실행한 증거가 아니다. StarNote 보호 본체를 복원했다는 뜻도 아니다. Rnote 코드·자산을 우리 제품에 복사하지 않았으며 아래는 계약을 비교해 자체 구현을 점검한 기록이다.

## 실제 읽은 계약

- [camera.rs 261–302행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/camera.rs#L261): viewport를 문서 좌표로 계산하고, 문서→화면 변환과 역변환을 구분한다. zoom 후 offset을 적용한다. [107–119행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/camera.rs#L107)의 offset 제한은 현재 동적으로 확장된 문서 영역에 대한 제한이다.
- [document/layout.rs 20–33행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/document/layout.rs#L20): 고정·세로 확장·양방향 무한 layout을 구분한다. [document/mod.rs 291–337행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/document/mod.rs#L291)의 infinite resize는 viewport 주위 padding과 필요하면 내용 bounds까지 합쳐 x/y/width/height를 확장한다. 처음부터 매우 큰 고정 종이를 놓는 방식이 아니다.
- [engine/rendering.rs 91–99행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/engine/rendering.rs#L91): 현재 viewport와 image scale에 필요한 내용을 스레드에서 재생성하도록 요청한다. [180–205행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/engine/rendering.rs#L180)은 viewport와 교차하는 획만 그리며 형광펜은 Multiply layer로 분리한다.
- [pens/brush.rs 71–129행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/pens/brush.rs#L71): Idle의 Down에서 획을 생성하고 Drawing/InProgress로 전환한다. [143–175행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-engine/src/pens/brush.rs#L143)은 Cancel에서도 이미 받은 획의 geometry/rendering을 마무리하고 history를 기록한다.
- [penpath/element.rs 14–19행](https://github.com/flxzt/rnote/blob/6bbc9b201adb0ab264f20dcdf6f23a18908eedfe/crates/rnote-compose/src/penpath/element.rs#L14): 문서 위치 Vector2와0–1 압력을 하나의 입력 요소로 보관한다.

## 자체 구현에 반영한 사항

- [InfiniteDocument](../lib/data/vault/infinite_document.dart)는 페이지 width/height 제한 없이 음수·먼 좌표와 압력을 version1 JSON에 저장한다. 문서 내용과 화면 viewport를 분리하고 역변환·고정 focal zoom을 제공한다. Rnote와 offset 부호는 다르지만 화면과 문서 좌표를 분리한다는 계약을 따른다.
- [InfiniteCanvas](../lib/pages/workspace/infinite_canvas.dart)는 화면과 교차하는 획 bounds를 검사한 뒤 그린다. 고정된 대형 페이지 대신 화면 크기의 CustomPainter를 사용한다. immutable 획의 bounds는 최초 계산 후 재사용한다.
- 펜·형광펜·획 지우개·올가미 이동, undo/redo, stylus 우선·선택적 손가락 필기와 터치 pan/pinch를 자체 구현했다. 조작 중 busy와 저장 dirty를 구분하고 저장을 직렬화한다. 저장 실패는 작업본을 유지하고 재시도를 제공한다.
- Cancel에서 마지막 유효 펜 획을 버리던 초기 구현을 수정했다. OS 입력 취소에서는 받은 펜/지우개 결과를 보존하고 선택 이동 취소는 적용하지 않는다. 두 손가락 이동으로 전환하는 미완성 손가락 획은 별도로 취소한다.

## 검증과 남은 차이

부모가 실행한 무한 필기 시험10개는 통과했다. 음수 좌표·왕복 JSON, 변환/zoom, 펜 저장, 저장 실패 보존, undo/redo·지우개·올가미, 터치 이동, 저장 중 새 변경 직렬화와 PointerCancel을 다룬다. 전체 workspace 연결·실기기 수용을 대신하지 않는다.

현재 자체 renderer는 획별 캐시 bounds를 순회하는 동기 벡터 그리기다. Rnote의 스레드 기반 render cache·공간 인덱스와 동등한 성능을 확인하지 않았다. 형광펜도 현재 단순 alpha이며 Rnote의 Multiply 합성과 같지 않다. S9+의 실제 S Pen 지연·팜 리젝션·큰 문서 부하·회전·백그라운드 복귀는 미검증이다. 이미지/PDF 페이지 필기와 무한 필기, 지식 연결용 카드 캔버스는 각각 다른 데이터와 수용 시험을 가진다.
