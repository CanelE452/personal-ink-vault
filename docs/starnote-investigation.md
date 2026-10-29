# StarNote Android 기능·정적 조사

2026-10-22. 사용자 요청에 따라 인터넷에서 공식 APK를 확보하고 기능 안내와 정적 구조를 조사했다. 첫 사용 기기는 Galaxy Tab S9+다. 앱 설치/실행·개인 노트 수집은 하지 않았다.

## 대상

[Google Play 대상](https://play.google.com/store/apps/details?id=com.onyx.galaxy.global.note&hl=en) → 공식 starnote.ai → [다운로드 페이지](https://starnote.ai/download)의 HTML Android 링크 → [공식 APK](https://static-us.boox.com/galaxy/apks/starnote_global_latest.apk) 순서로 출처를 확인했다. 동명 starnote.app·미러·중국 지역판은 사용하지 않았다.

```text
package       com.onyx.galaxy.global.note
versionName   1.5.4
versionCode   5705
minSdk        29
targetSdk     36
compileSdk    36
bytes         456682652
SHA-256       5a0e55c79a7d13c2c18f192025541fe497193214ed97157b3a2e9043ccc52c5b
```

[확인] Binary XML string pool/start-element attribute를 구조적으로 파싱한 패키지·버전·SDK 결과다. 별도 SHA-256 계산과 REA open_binary 해시가 일치했다. latest URL은 이후 바뀔 수 있으므로 해시로 대상을 고정한다. **서명/게시자 인증서 검증은 미실시**이며 공식 링크·해시는 이를 대신하지 않는다.

로컬 APK: `C:\Users\User\AppData\Local\Temp\personal-ink-vault-research\starnote\starnote_global_latest.apk`. 저장소 밖 임시 연구 폴더이며 공개 Git에 넣지 않았다.

## 공식 기능 안내 — 실측 아님

현재 Play 설명은 펜·형광펜·지우개·도형·텍스트·레이어·올가미, PDF 가져오기/필기/내보내기, 폴더/태그/링크/페이지 관리, 템플릿, 암기용 테이프, PIP, AI 음성 요약을 안내한다. 업데이트에는 많은 노트에서 발생하던 cloud sync 오류 수정이 있다. **이 설명만으로 실제 Drive 자동 동기화 방식·충돌·복구 품질을 확정하지 않는다.** [공식 설명](https://play.google.com/store/apps/details?id=com.onyx.galaxy.global.note&hl=en).

모든 기능을 MVP에 추가하지 않는다. 현재 합의 흐름에 필요한 PDF 필기·연결·기기 간 전달을 우선하고 다른 기능은 실제 필요를 확인한 뒤 제안한다.

## APK 관찰과 추정

- [확인] Manifest Application은 `com.sagittarius.v6.StubApplication`. 최상위 classes.dex는 35,672 bytes이고 29개 클래스가 wrapper 계열이다.
- [확인] libbaiduprotect.so와 assets/baiduprotect*가 있으며 ZIP 형태 baiduprotect1~16.i.dex 내부 DEX의 class_defs_size는 0이다. **[추정] 보호 래퍼 구조**이며 원래 앱의 기능 코드를 복원한 결과가 아니다.
- [확인] ABI는 arm64-v8a/armeabi-v7a, .so는 85개다. Room 2.5.0·WorkManager 2.9.0·motionprediction 1.0.0-beta03·coroutines 1.7.3 메타데이터가 포함된다. 포함 사실은 실제 사용 경로의 증거가 아니다.
- [확인] assets/js/config.js에 Tiptap starter-kit/color/font-family/highlight/task-list/text-align 등의 import가 있다. richEditor HTML/JS·ProseMirror 자산도 있다. **[추정] 웹 리치텍스트 구성 후보**이며 Markdown 원문 저장/Windows 지원의 증거가 아니다.
- [확인] assets/mlkit-google-ocr-models/.../Kore_ctc/... 및 lib/arm64-v8a/libmlkit_google_ocr_pipeline.so, handwriting 관련 자산과 ONNX/sherpa/MMKV/LiteCore JNI 라이브러리가 있다. 인식/음성 구성의 단서이며 실제 오프라인 실행·한국어 품질·통신은 미검증이다.
- [확인] ZIP 경로 검색에서 일반적인 libflutter.so/libapp.so/flutter_assets는 발견하지 못했다. 이 부재만으로 UI 전체의 구현 기술을 단정하지 않는다.

ZIP 파일 항목은 15,766개다. REA occurrence 15,767개는 root를 포함한 관점으로 구분한다. 전체 해제는 하지 않았다. REA가 대소문자 접힘 충돌을 보고해 Windows 전체 해제 시 덮어쓰기 가능성이 있으므로 필요한 entry만 정확한 이름으로 메모리에서 읽었다.

## REA와 로컬 증거

- [확인] open_binary와 inspect_artifact(summary) 성공. integrity contradiction 0은 APK 서명/기능 검증을 뜻하지 않는다.
- inventory Evidence: `ev_dbf788781b5452259439e412bf3c6da16556ad35a3acac2e35c6453ed004ff5d`.
- inspection Evidence: `ev_2357b0db1442ebdb2a5c9221b40f6db1d463b943773e51f38caa709b84303e36`.
- summary Evidence: `ev_c98a6c152e5482452425459c9c1f4ef583be3f7035525ba5df125b4e915740ac`.
- bundle: `C:\Users\User\AppData\Local\Temp\personal-ink-vault-research\starnote\rea-evidence.json`(32,788,724 bytes, 3 records). export 후 close_binary로 세션을 닫았다. 로컬 전용이다.
- [확인] inspect_adb_client는 adb 실행 파일 부재, inspect_android_package는 REA_JADX_MCP_JAR 미설정으로 실패했다. PATH와 일반 SDK/JDK 위치에서도 실행 파일을 확인하지 못했다. PC 전체에 없다는 전역 탐색 결과는 아니다.
- Android 심층 provider에는 caller-supplied jadx-headless-mcp 0.7.1과 full JDK17+가 필요하다. 공식 고정 도구/portable 경로는 조사했지만 추가 설치나 Codex/REA/PATH 변경은 하지 않았다. 현재 wrapper에 JADX를 추가하는 것만으로 본체 복원이 된다고 가정하지 않는다.

## 답변 범위

**확보한 결과:** 공식 기능 목록, 공식 APK·패키지·버전, archive/Manifest/번들 구조, 보호 래퍼와 편집·인식 구성 단서.

**미검증:** 원래 앱의 기능 호출 흐름, 펜 지연/손바닥 거부/회전 PDF, .note 페이지·획 저장, PDF annotation 보존, Drive 자동 동기화·충돌·삭제·복구, APK 서명.

다음 기능 확인은 S9+의 개인정보 없는 새 노트로 필기·레이어·올가미·회전 PDF·종료/재열기·공식 Drive 설정을 관찰하는 방법이 직접적이다. 필요한 경우 정적 도구를 준비해 wrapper 밖 Manifest/리소스를 보강한다. .note 호환은 별도 합성 샘플로 파싱→보기→편집→왕복을 나눠 검증한다. 앱 코드/자산은 우리 앱으로 복사하지 않는다.
