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
| **Jarvis에게 말 걸기** | 노치 옆 Jarvis 빛(또는 ⌥J)을 **누르고 있는 동안** 말하고, 떼면 Jarvis가 소리로 답함. 마이크는 누르는 동안에만 켜짐. 답하는 중에 다시 누르면 끼어들기. 들은 말과 답은 노치 대화에 같이 쌓임. **녹음 중에는 쉼**(강의 녹음을 건드리지 않음). 2분 동안 조용하면 연결을 닫음 | Jarvis와 함께 |
| **AI 에이전트 상태** | Claude Code · Codex 세션을 감지해 상태를 캐릭터로 표시. 승인을 기다리면 노란 「!」. 누르면 해당 앱이 열림 | 숨김 |
| **달력 · 오늘 할 일** | 3주 달력과 오늘 목록. macOS 미리 알림을 직접 읽어 체크하면 바로 빠짐 | 숨김 |
| **자주 가는 곳** | 사이트 · 폴더 · 파일을 한 번에 열기. 노치에 끌어다 놓으면 추가 | 켜짐 |
| **시스템 모니터** | 노치를 펼치면 맨 아래 한 줄에 CPU · 온도 · RAM · 네트워크(↓ ↑). 노치가 접혀 있으면 안 보임 | 켜짐 |
| **메뉴바 고양이** | [RunCat Neo](https://github.com/runcat-dev/RunCatNeo)의 고양이가 CPU 사용률만큼 빨리 달림. 누르면 노치가 열리고 닫힘, 오른쪽 클릭에 숨기기 | 켜짐 |
| **그 밖에** | 지금 재생 중인 음악, 클립보드, 파일 선반, 집중 타이머 | 숨김 |

## 기술 구성

- **Swift 6 · SwiftUI · AppKit** (`NSPanel`로 노치에 붙는 패널) · Observation
- **XcodeGen** — `project.yml`에서 Xcode 프로젝트를 만듭니다
- **Swift Testing** — 단위 테스트 243개 (`NotchAITests/`)
- 음성 전사: [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (`large-v3-turbo` 모델)
- 재생 정보: [mediaremote-adapter](Vendor/mediaremote-adapter) (BSD-3, 원저작자 라이선스 포함)
- 메뉴바 고양이: [RunCat Neo](https://github.com/runcat-dev/RunCatNeo) (Apache 2.0) · CPU·메모리 계산: [SystemInfoKit](https://github.com/Kyome22/SystemInfoKit) (Apache 2.0) · 온도 센서 목록: [Stats](https://github.com/exelban/stats) (MIT) — 자세한 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## 시스템 모니터 · 메뉴바 고양이 (2026-11-09)

Stats와 RunCat Neo를 따로 켜 두던 것을 NotchAI 하나로 합쳤습니다. 측정은 한 곳(`SystemMonitor`)에서 1초에 한 번만 하고,
고양이와 노치가 같은 값을 씁니다.

| 지표 | 무엇을 · 어떻게 | 주기 |
| --- | --- | --- |
| CPU | 전체 코어 사용률 = (user + system) ÷ 전체 tick (`host_cpu_load_info`). 고양이 속도 = CPU% ÷ 5 (1–20배, RunCat Neo 그대로) | 1초 · 항상 (고양이가 켜져 있으면) |
| 온도 | CPU 코어 센서 중 가장 높은 값 (SMC, Stats 「Hottest CPU」와 같은 센서·계산). M5는 18개 키 중 응답하는 것. 모르는 칩·실패는 `N/A` | 3초 · 노치가 열려 있을 때만 |
| RAM | 사용 = 앱 + 고정 + 압축 (캐시·파일 페이지는 뺌, 활성 상태 보기와 같은 계산) ÷ 전체. 메모리 압력이 「주의」면 노랑, 「위험」이면 빨강 | 1초 |
| 네트워크 | 기본 경로 인터페이스(Wi-Fi 등) 바이트 카운터의 1초 변화량. 연결이 없으면 「연결 없음」(0 B/s와 구분) | 1초 |

각 숫자 위에 마우스를 올리면 자세한 값(센서 개수, 사용 GB, 인터페이스 이름)이 나옵니다. `…` 메뉴 「노치에 보이기」에서
시스템 모니터와 메뉴바 고양이를 각각 끌 수 있고, 둘 다 끄면 측정도 멈춥니다. 잠자기 동안은 측정을 멈추고, 깨어나면
기준값을 버려 첫 숫자가 튀지 않게 합니다. 온도는 관리자 권한·도우미 프로그램 없이 읽습니다(읽기만, SMC에 쓰지 않음).

## 저장소 구조

```
NotchAI/            본체 앱
├── Notch/          노치 위치 계산 · 접힘/펼침 패널
├── Character/      상태 캐릭터
├── Providers/      Claude · Codex 연결
├── Services/       감지 · 녹음 · 전사 · 달력 · 미리 알림 …
├── SystemMonitor/  CPU · 온도 · RAM · 네트워크 측정, 메뉴바 고양이, 노치 하단 줄
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
