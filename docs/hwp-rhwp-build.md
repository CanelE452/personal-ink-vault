# 한글(HWP·HWPX) 엔진과 편집 화면 빌드

Android 216부터 한글 문서의 PDF 변환 엔진과 편집 화면은 upstream rhwp의 같은 커밋으로 만든다. 이 문서는 그 소스를 다시 받아 같은 결과를 만드는 방법을 적는다.

- 원본: <https://github.com/edwardkim/rhwp>의 `refs/pull/9022/head`, 커밋 `4cf97fe5f40bde52b6e80dfc461b5111b51139b6`. 라이선스는 MIT다.
- 이 PR은 아직 병합·출시되지 않았다. 표 칸 안의 어울림 그림과 본문이 겹치던 배치 문제를 고친다(출시판 0.9.0에는 이 문제가 있다).
- rhwp 출시판에 이 수정이 들어오면 아래의 임시 경로를 지우고 그 출시판으로 고정한다.

## 1. 원본 받기

```bash
git clone https://github.com/edwardkim/rhwp rhwp-0.9.0-dev-4cf97fe5
cd rhwp-0.9.0-dev-4cf97fe5
git fetch origin refs/pull/9022/head
git checkout 4cf97fe5f40bde52b6e80dfc461b5111b51139b6
```

## 2. PDF 변환 엔진 (`packages/ink_hwp_native`)

- `Cargo.toml`의 `[patch.crates-io] rhwp = { path = "..." }`가 위에서 받은 폴더를 가리킨다. 빌드한 PC의 경로가 그대로 적혀 있으니, 다른 PC에서는 이 경로만 받은 폴더로 바꾼다. `Cargo.lock`은 그대로 쓴다.
- 엔진 버전 문자열은 `ink_hwp_native/0.1.0+rhwp.0.9.0-dev.4cf97fe5`다.
- Android 라이브러리(`libink_hwp_native.so`, arm64)는 빌드한 뒤 `llvm-strip --strip-unneeded`로 기호표를 뺀 것을 APK에 넣는다.
- 고지 파일 `THIRD_PARTY_LICENSES.txt`는 `packages/ink_vault_native/generate_licenses.py`가 만든다. 이 경로 패키지들도 출처 커밋과 함께 싣는다.

## 3. 편집 화면 (`android/office_engine/hwp_editor`)

앱의 "Office 편집용" 한글 편집 화면은 rhwp-studio를 WebView에 띄운 것이다.

1. 위 원본에 이 폴더의 `rhwp-studio-loaddocument-retry.patch`를 적용한다. 원본 저장소 최상위에서 `git apply`로 넣는다.
   - 느린 태블릿에서 글꼴 로드 완료 신호가 문서 로드를 밀어내면 빈 쪽만 보이던 문제를 고친다. 문서 로드를 최대 8번 다시 시도한다.
2. 빌드한다. 쓴 도구는 Rust 1.99.1(`wasm32-unknown-unknown` 대상), wasm-pack 0.14.0(wasm-bindgen 0.2.127), Node v24.22.3, npm 11.19.1이다.

   ```bash
   wasm-pack build --target web --release --out-dir pkg
   cd rhwp-studio
   npm ci
   RHWP_DISABLE_EXTERNAL_WEBFONTS=1 npm run build
   ```

   - 216·217은 wasm-opt 없이 wasm-bindgen 출력을 그대로 썼다. 빌드 PC에서 wasm-opt가 실패했기 때문이다(os error 5).
3. APK의 `assets/hwp-studio/`에 넣는다.
   - `rhwp-studio/dist`의 파일 전부. 단 PWA 서비스 워커(`sw.js`, `workbox-*.js`, `registerSW.js`, `manifest.webmanifest`), 예제 문서(`samples/`), 형식 선언(`*.d.ts`)은 뺀다.
   - `index.html`에서 manifest 링크와 서비스 워커 등록 태그를 지우고, `<head>` 바로 뒤에 `<script src="/__piv/studio-config.js"></script>`를 넣는다.
   - `__piv/`에 이 폴더의 `host.html`, `host.js`, `studio-config.js`를 넣는다.
   - `__piv/rhwp-editor/`에 같은 커밋의 `npm/editor/`에서 `index.js`, `transport.js`, `document-agent-contract.js`, `LICENSE`를 넣는다.
   - rhwp의 `LICENSE`를 `LICENSE-rhwp.txt`로, `THIRD_PARTY_LICENSES.md`를 같은 이름으로 넣는다.
4. 앱은 이 편집기를 `?chrome=embed`로 띄운다. 그러면 시작용 빈 문서, 복구 안내, 편집기 자체의 파일 메뉴(새로 만들기·열기·저장·인쇄)가 꺼지고, 앱의 "저장하고 닫기"만 저장한다. `studio-config.js`는 편집기 자체의 자동 저장·복구 기록도 끈다.
