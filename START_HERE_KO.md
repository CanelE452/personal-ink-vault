# Windows Codex에서 이어가기

**현재 개발 상태:** 사용자가 세 앱 분석 반영과 MVP 개발 시작을 승인했습니다. `codex/mvp-foundation`에서 구현 중이며 [개발 계획](docs/roadmap.md)의 실행 현황 → [설계](docs/mvp-design.md) → [인계](HANDOFF_KO.md)를 읽고 실제 파일/테스트 상태를 확인하세요. 아래 '앱 구현 전' 및 기술/MVP를 다시 정하라는 첫 대화 예시는 초기 기록입니다. 기존 합의를 다시 묻거나 구현을 처음부터 재시작하지 마세요.

현재 새 대화에는 다음을 사용하세요.

```text
HANDOFF_KO.md, docs/mvp-validation.md, docs/roadmap.md를 읽고 실제 Git 상태부터 확인해줘.
Saber 기반 검증판과 저장·Drive·Markdown 코드는 이미 구현됐어.
기존 코드를 보존하고 Windows 앱 실행, 실제 앱 로그인/권한 동의, S9+↔Windows 실기기 검증이라는 남은 gate부터 이어가줘.
C++ 도구 설치·Windows Release 빌드·Cloud의 3종 OAuth client 등록은 완료됐으니 반복하지 마.
단위시험·APK 빌드와 실제 계정/기기 성공을 구분하고, 요청 전 commit/push는 하지 마.
```

**후속 현황(2026-10-22):** 첫 MVP는 Galaxy Tab S9+ PDF 필기·Windows Markdown 정리·Drive 자동 동기화로 합의했습니다. 읽기 순서는 [최신 인계](HANDOFF_KO.md) → [Saber 검토](docs/saber-reuse-review.md) → [설계](docs/mvp-design.md) → [계획](docs/roadmap.md) → [StarNote 조사](docs/starnote-investigation.md)입니다. REA 노출/공식 APK 정적 조사는 확인했고 앱 구현·실기기·.note 호환은 미완료입니다. 아래는 후속 합의 전 초기 안내입니다.


2026-10-22 인계입니다. **프로젝트 준비와 REA 연결은 완료했고, 앱 구현은 아직 시작하지 않았습니다.**

Android StarNote 같은 손필기·PDF 주석과 Obsidian 같은 Markdown·링크·역링크·태그·검색·그래프를 결합하는 개인용 앱이 목표입니다. Android 휴대폰·태블릿, iPhone·iPad, Windows에서 사용하는 것을 목표로 합니다.

공개 GitHub에는 코드·문서만 둡니다. 개인 필기·PDF·백업은 비공개 Google Drive에 두는 구조이며, Drive 연결과 동기화는 아직 구현하지 않았습니다.

## 열 위치

- Codex 앱의 기존 프로젝트: `personal-ink-vault`.
- Windows 폴더: `C:\Users\User\Documents\Codex\2026-10-22\task-4\personal-ink-vault`.
- 공개 저장소: [CanelE452/personal-ink-vault](https://github.com/CanelE452/personal-ink-vault).
- 이 프로젝트에서 새 대화를 시작하면 됩니다. 프로젝트 등록과 VS Code 폴더 열기는 앞선 작업에서 완료했습니다.

## 읽기 순서

1. [HANDOFF_KO.md](HANDOFF_KO.md): 완료한 일, REA 설치 결과, 미확정 결정과 다음 체크리스트.
2. [README.md](README.md) → [요구사항](docs/requirements.md).
3. [기술 후보 비교](docs/architecture-options.md) → [호환성 조사](docs/compatibility-research.md) → [개발 계획](docs/roadmap.md).

기존 준비 문서의 “역공학 스킬 미설치·URL 미제공”은 REA 설치 전 기록입니다. 이후 상태는 인계 문서의 REA 절을 참고하세요. REA 6.7.0의 초기화와 도구 목록 응답은 검증했지만, Codex 재시작 후 새 대화에서의 도구 노출은 아직 확인하지 않았습니다.

## 새 대화에 넣을 첫 메시지

```text
이 Windows personal-ink-vault 프로젝트를 이어서 진행하고 싶어.
START_HERE_KO.md, HANDOFF_KO.md와 연결된 기존 문서를 먼저 읽고,
실제 Git 상태를 확인한 뒤 목표와 완료·미완료 상태를 짧게 설명해 줘.
PWA와 Flutter/Saber 중 첫 실험 경로, MVP 범위,
Google Drive를 백업으로 쓸지 양방향 동기화로 쓸지 나와 정해 줘.
아직 정하지 않은 기술을 확정된 것으로 취급하지 말고,
REA는 새 대화의 도구 노출 여부부터 확인해 줘.
```

이 두 인계 파일은 이번에 로컬에만 작성했습니다. 커밋·push는 하지 않았으므로, 다른 PC에서 clone한 저장소에는 아직 없습니다.
