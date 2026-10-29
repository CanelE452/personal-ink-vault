# Obsidian 1.14.4 역공학 1차 조사

2026-10-22. 사용자 요청으로 공식 데스크톱 배포 패키지를 확보해 저장·메타데이터·링크/역링크·이름 변경·검색·그래프·PDF·플러그인 경계를 조사했다. `[확인]`은 별도 표시가 없으면 **배포 코드의 정적 경로 확인**이며 앱 실행 시험이 아니다. 개인 vault에 접근하거나 앱을 설치/실행하지 않았다.

## 대상과 출처

일반 Windows 설치 경로·설치 목록·Obsidian 프로세스에서 대상을 찾지 못해 [공식 다운로드](https://obsidian.md/download)가 사용하는 [공식 release v1.14.4](https://github.com/obsidianmd/obsidian-releases/releases/tag/v1.14.4)의 [ASAR 업데이트 패키지](https://github.com/obsidianmd/obsidian-releases/releases/download/v1.14.4/obsidian-1.14.4.asar.gz)를 받았다. PC 전체를 탐색한 결과는 아니다.

```text
release               v1.14.4
release published     2026-10-05T17:03:28Z
asar.gz bytes         9200670
asar.gz SHA-256       d1ed428c363968774f0f3906e67d8a53a058ece0b6cdd924b07865977b2ada21
asar bytes            27477966
asar SHA-256          146ef8470d8cbb4a6db209bdc19bf2bad13350444186c0fd93c31087b142b92f
app.js SHA-256        958ce57fe22f87fdf121546e46dfccd9c8ee971ce3fd8f801d60d4ece39a2df9
worker.js SHA-256     a42f7927658132927e124131fdb7fc69fdb2853097c24158e0fdb245b87c34ae
sim.js SHA-256        549be2f69710af360d521c92b80c83718f673594d3dc2255a65e251199eee25d
```

[확인] 다운로드 SHA-256이 GitHub release API의 asset digest와 일치했다. ASAR 368개 항목을 경로 검사 후 저장소 밖에 풀었고 368개 모두의 per-entry SHA256 integrity가 일치했다. package.json 버전도 1.14.4다. 이 확인은 Authenticode/실행 파일 서명 검증은 아니다.

로컬 연구 폴더는 `C:\Users\User\AppData\Local\Temp\personal-ink-vault-research\obsidian`이다. 원본 압축·ASAR·extracted·inventory·증거는 이 폴더에만 있다. 공개 저장소에는 분석 설명을 저장하며 Obsidian 코드/자산을 앱에 통합하지 않았다.

## 조사 방법과 한계

REA analyze_javascript_application에 ASAR과 package.json/index.html/main.js/app.js/worker.js/sim.js를 명시했다. 4개 JS가 구문 분석됐고 parse failure는 0이었다. JS/HTML은 텍스트로만 파싱했다. 추가로 해당 함수의 몸체·호출·상태 갱신을 좁혀 읽고 PDF viewer 파일을 별도로 확인했다.

**전체 역공학 완료가 아니다.** REA 관련 파일 38개 중 선택하지 않은 32개가 있고, semantic 한도를 파일당 3000 node/2000 unknown으로 설정했다. application/semantic coverage는 partial이며 semantic unknown 7656개가 남았다. 없는 자동 graph edge를 기능 부재로 해석하지 않았다.

이 ASAR은 업데이트 패키지다. package.json의 main은 index.js지만 그 파일은 포함되지 않는다. main.js의 Electron 경로는 확인했지만 installer/launcher/native dependency 전체를 조사한 것으로 확대하지 않는다. source map도 없었다. Android/iOS 동작·성능·개인 플러그인·Sync 서버 프로토콜은 이 조사 결과가 아니다.

## 핵심 결과

1. **파일과 파생 캐시 [확인]:** 파일 변경 이벤트가 metadata 작업을 큐에 넣는다. 경로별 mtime/size/hash와 내용 해시별 파싱 결과를 분리하고, 시작 시 파일 상태와 IndexedDB 캐시를 대조해 필요한 항목을 다시 계산한다.
2. **링크/역링크 [확인]:** worker가 링크·embed·frontmatter 참조와 위치를 추출한다. 앱은 목적지 해석 후 sourcePath별 resolved/unresolved 링크 수를 만든다. 역링크 패널은 후보를 좁힌 뒤 실제 목적지를 다시 확인해 참조 위치를 표시한다.
3. **이름 변경 [확인]:** 일반 rename은 파일 객체의 경로와 map 키를 바꾼다. 별도 FileManager 경로는 기존 참조 대상을 보관하고 변경 뒤 재해석해 본문 갱신을 처리한다. 관찰한 키는 경로이지만 앱 전체에 내부 UUID가 없다고 단정하지 않는다.
4. **검색 [확인]:** 입력→공통 쿼리 matcher→큐→캐시/필요한 본문 읽기→결과 갱신이다. 이 경로는 별도 전문 역색인 worker를 호출하지 않는다. 조사한 worker의 메시지 분기는 metadata/section 파싱이다.
5. **그래프 [확인]:** 링크 해석 결과와 태그로 노드/링크를 만들고 공통 matcher로 필터링한다. 별도 sim.js worker가 force simulation 좌표를 계산해 buffer로 반환하고 화면이 렌더링한다. 확인한 표시 경로는 노트/링크 정보에서 그래프를 생성한다.
6. **PDF [확인]:** vault resource URL로 PDF viewer를 열고 페이지·선택 텍스트·기존 annotation 앵커/팝업을 연결한다. 이 wrapper에서 펜 획 생성→모델→vault 저장 경로는 확인하지 못했다. PDF.js 편집 옵션은 있어 앱 전체의 잉크 미지원으로 단정할 수 없다.

위 결과는 지정한 함수 경로에 대한 정적 확인이다. 실제 실행 순서/지연/경쟁조건·모든 입력에서의 정확성을 보장하지 않는다.

추가로 config JSON은 vault configDir 경로의 읽기/쓰기로 이어진다. workspace.json/workspace-mobile.json과 최근 파일/탭 상태가 별도 관리되고, core plugin과 community plugin manager도 분리돼 있다. community loader는 manifest/main.js를 읽어 플러그인을 인스턴스화하고 수명주기/CSS를 연결하는 경로다. 플러그인을 실행하거나 권한 격리 수준을 실증하지 않았다.

## 재현 가능한 코드 위치

아래 범위는 **UTF-8 바이트, 0-based, 끝 제외**다. minify된 파일의 줄 번호보다 해당 버전의 해시+범위로 식별한다. 대표 anchor 11개가 실제 범위에 있는지 별도 검사했다. 범위 일치는 호출 흐름 검토를 대체하지 않는다.

```text
파일                             범위                 조사 경계
app.js                           1759471..1759825     파일 변경 구독
app.js                           1765845..1768095     metadata 계산·캐시
app.js                           1764553..1764878     링크 목적지 집계
app.js                           1794479..1797388     rename·참조 갱신
app.js                           3078037..3081806     역링크 패널
app.js                           2713477..2723312     검색 큐·결과
worker.js                         236649..239777      metadata/section 분기
app.js                           2392472..2406650     그래프 renderer/worker
sim.js                             5329..17693       좌표 simulation
app.js                           2660912..2679217     PDF wrapper
lib/pdfjs/pdf.viewer.min.mjs      481469..487686       PDF viewer 구성
```

상세 원본 참조/구간 해시는 연구 폴더의 manual-source-references.json에 있다. PDF viewer SHA-256은 `7060308a7ffa11ab3112458ec58f740eb90643849beeaa6d9c9ff4441e9d35af`다.

## 공식 문서/API와 대조

[공식 저장 설명](https://help.obsidian.md/Files+and+folders/How+Obsidian+stores+data)은 Markdown 파일·vault 설정·재구축 가능한 cache를 설명한다. [공개 API 타입](https://github.com/obsidianmd/obsidian-api/blob/master/obsidian.d.ts)은 Vault/MetadataCache/FileManager 계약이며 본체 구현 소스가 아니다. 최신 master 계약을 이 배포 버전과 동일하다고 가정하지 않았다.

[Backlinks](https://help.obsidian.md/Plugins/Backlinks)는 실제 링크와 미연결 언급을 구분하고, [Graph](https://help.obsidian.md/Plugins/Graph+view)는 필터/이웃 탐색을, [Search](https://help.obsidian.md/Plugins/Search)는 쿼리 연산자를 안내한다. 공식 사용 설명과 이번 정적 경로는 구분해 읽어야 한다.

## personal-ink-vault에 적용할 제안

- PDF/필기/Markdown을 원본으로 두고 검색·역링크·그래프를 재구축 가능한 파생 정보로 둔다.
- 파싱 완료와 링크 해석 완료를 구분하며 resolved/unresolved 참조를 함께 유지한다. 검색과 그래프가 같은 필터 의미를 공유하도록 한다.
- 우리 앱의 noteId/pageId 방침은 유지한다. 표시 제목·경로·링크 문자열·영구 ID를 구분하고, 제목 변경/동명 문서/상대 링크/페이지 재배치를 시험한다.
- PDF 보기/페이지 앵커와 펜 획 모델/영속 저장을 별도 경계로 둔다. Obsidian PDF viewer 분석으로 Saber 필기 품질이 검증되지는 않는다.
- 그래프 좌표/복잡한 plugin 확장은 현재 MVP 다음 단계다. 이번 조사로 합의한 MVP 범위를 확대하거나 기존 설계를 자동 변경하지 않았다.

## 증거와 남은 일

REA parent Evidence: `ev_2d54885287f309e04f2560ed5b018ae6b4c0b1b3b8c36bf9c10981dda5f4156f`.
summary Evidence: `ev_e28020b42d34e296191f38ce677d45a3c15bc11a6d6c39f079d4a120ad1499f1`.
main source-module projection: `ev_503b83c50d6a29d518249bcb1f5295745aae94045b97bce058d7fad2c48c4669`.

bundle은 연구 폴더의 obsidian-1.14.4-rea-evidence.json에 export했다(26,535,295 bytes, 4 records). 이후 close_binary로 세션을 닫았다. bundle 최상위 unknown 수와 parent graph의 unresolved 수는 다른 범위이므로, export 성공을 전체 의미 해석 완료로 표시하지 않는다.

다음 실증 대상은 개인정보 없는 별도 vault에서 생성/수정/rename·동명 링크·미해결 링크·검색/그래프·PDF 앵커를 재현하는 것이다. 현재는 실행 검증·Sync 프로토콜·모든 기능/플랫폼 분석이 남아 있다. 설치·개인 vault 수정·앱 코드 복사·commit/push는 하지 않았다.
