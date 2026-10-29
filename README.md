# NotchAI

> 맥북 노치에 사는 작업 비서. Claude Code · Codex가 지금 뭘 하는지 노치에서 바로 보입니다.

노치 옆의 작은 캐릭터가 AI 코딩 에이전트의 상태(생각 중 · 작업 중 · 승인 대기 · 완료 · 오류)를
빛과 움직임, 표정으로 보여줍니다. 노치를 펼치면 달력, 오늘 할 일, 녹음, 자주 가는 곳이 한 화면에 모여 있습니다.

쓰던 노치 앱이 원하는 정보를 제대로 못 보여줘서 직접 만들었고, 2026-09-19부터 매일 쓰고 있습니다.

## 주요 기능

| 기능 | 내용 |
| --- | --- |
| **AI 에이전트 상태** | Claude Code · Codex 세션을 감지해 상태를 캐릭터로 표시. 승인을 기다리면 노란 「!」. 누르면 해당 앱이 열림 |
| **달력 · 오늘 할 일** | 3주 달력과 오늘 목록. macOS 미리 알림을 직접 읽어 체크하면 바로 빠짐 |
| **녹음 · 전사** | 마이크 · 시스템 소리 녹음, whisper.cpp로 **맥 안에서** 전사 (인터넷으로 보내지 않음, 유료 API 없음) |
| **그 밖에** | 지금 재생 중인 음악, 클립보드, 파일 선반, 집중 타이머, 자주 가는 곳 |

## 기술 구성

- **Swift 6 · SwiftUI · AppKit** (`NSPanel`로 노치에 붙는 패널) · Observation
- **XcodeGen** — `project.yml`에서 Xcode 프로젝트를 만듭니다
- **Swift Testing** — 단위 테스트 130개 (`NotchAITests/`)
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

## AI 활용

기획 · 기능 결정 · 사용 검증은 직접 하고, 구현은 Claude Code와 Codex에 작업을 지시해 진행했습니다.

---

**만든 사람** · 정동근 ([GitHub](https://github.com/donggeun6669-cyber) · donggeun6669@gmail.com)
