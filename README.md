# NotchAI

> 맥북 노치에 사는 작업 비서. 강의 녹음, 그리고 개인 비서 Jarvis와의 대화가 노치에서 바로 됩니다.

노치를 펼치면 왼쪽은 집 데스크탑의 개인 비서 **Jarvis와 대화**하는 칸, 오른쪽은 **녹음**과 **자주 가는 곳**입니다.
녹음 중에는 노치 옆에 시간과 입력 레벨이 보이고, 녹음이 실패하면(시작할 때 3초 동안 소리가 안 들어오면)
빨간 「녹음 안 됨」이 확인할 때까지 남습니다. 그 밖의 기능은 처음엔 숨겨져 있고, `…` 메뉴 「노치에 보이기」에서
하나씩 켭니다. 꺼 둔 기능은 아예 돌지 않습니다.

쓰던 노치 앱이 원하는 정보를 제대로 못 보여줘서 직접 만들었고, 2026-09-19부터 매일 쓰고 있습니다.

## 주요 기능

| 기능 | 내용 | 처음 상태 |
| --- | --- | --- |
| **녹음 · 전사** | 강의실(마이크) · 온라인(맥 소리 — 스피커 · 에어팟 · 무음) 4가지. 시작 전 3초 입력 확인, 녹음 중 무음 · 저장 밀림 감시, 끝나면 파일 검증. whisper.cpp로 **맥 안에서** 전사 (인터넷으로 보내지 않음, 유료 API 없음) | 켜짐 |
| **Jarvis** | 집 데스크탑의 개인 비서. 노치 옆 작은 빛으로 쉬는 중 · 생각 중 · 작업 중(돌아가는 일 수만큼 작은 점) · 승인 대기, 닿지 않으면 빗금 친 회색 고리. 펼치면 대화(답이 쓰이는 대로 보이고, 쓰는 도구도 보임) · 최근 작업 · **결재**는 노치 옆 패널 카드로(코드는 꾹 눌러 승인, 메일 초안은 한 번에 확인, 반려는 5초 안에 되돌리기 — 결과는 서버가 알려 준 것만) · 「앱에서 열기」. 노치 대화는 하루 동안 이어짐 | 주소를 넣으면 |
| **AI 에이전트 상태** | Claude Code · Codex 세션을 감지해 상태를 캐릭터로 표시. 승인을 기다리면 노란 「!」. 누르면 해당 앱이 열림 | 숨김 |
| **달력 · 오늘 할 일** | 3주 달력과 오늘 목록. macOS 미리 알림을 직접 읽어 체크하면 바로 빠짐 | 숨김 |
| **자주 가는 곳** | 사이트 · 폴더 · 파일을 한 번에 열기. 노치에 끌어다 놓으면 추가 | 켜짐 |
| **그 밖에** | 지금 재생 중인 음악, 클립보드, 파일 선반, 집중 타이머 | 숨김 |

## 기술 구성

- **Swift 6 · SwiftUI · AppKit** (`NSPanel`로 노치에 붙는 패널) · Observation
- **XcodeGen** — `project.yml`에서 Xcode 프로젝트를 만듭니다
- **Swift Testing** — 단위 테스트 195개 (`NotchAITests/`)
- 음성 전사: [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (`large-v3-turbo` 모델)
- 재생 정보: [mediaremote-adapter](Vendor/mediaremote-adapter) (BSD-3, 원저작자 라이선스 포함)

## 저장소 구조

```
NotchAI/            본체 앱
├── Notch/          노치 위치 계산 · 접힘/펼침 패널
├── Character/      상태 캐릭터
├── Providers/      Claude · Codex 연결
├── Services/       감지 · 녹음 · 전사 · 달력 · 미리 알림 …
└── Views/          화면
NotchDesk/          AI 연동을 뺀 일반 사용자용 버전
LectureRecorder/    강의 녹음 · 전사만 떼어 낸 앱
NotchAITests/       단위 테스트
scripts/            빌드 · 실행 · 배포 묶음 스크립트
```

## 실행하기

요구 사항: 노치가 있는 Apple Silicon 맥북, macOS 26 이상, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen cmake
xcodegen generate
scripts/run.sh          # 빌드하고 실행
scripts/run.sh test     # 테스트
```

달력 · 자주 가는 곳 일부는 제 개인 작업 폴더(`~/Documents/DEAN`)의 파일을 읽도록 되어 있습니다.
다른 맥에서 쓰려면 `NotchAI/Services/ScheduleService.swift`와 `LauncherService+DEAN.swift`의 경로를 바꿔야 합니다.
Jarvis는 처음엔 꺼져 있습니다. 노치 `…` 메뉴의 「Jarvis 연결하기…」에 자기 Jarvis 서버 주소(Tailscale 사설망 주소)를 넣으면 켜집니다. 주소는 그 맥에만 저장됩니다.

## AI 활용

기획 · 기능 결정 · 사용 검증은 직접 하고, 구현은 Claude Code와 Codex에 작업을 지시해 진행했습니다.

---

**만든 사람** · 정동근 ([GitHub](https://github.com/donggeun6669-cyber) · donggeun6669@gmail.com)
