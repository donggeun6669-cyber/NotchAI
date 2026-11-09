# Third-party notices

NotchAI includes or adapts the following open-source work.

## RunCat Neo — Apache License 2.0

- Source: https://github.com/runcat-dev/RunCatNeo (commit `592cd60`, 2026-10-19)
- Copyright 2026 Kyome22 (Takuto Nakamura)
- Used: the cat runner's five frames (`NotchAI/Resources/RunCat/runcat-cat-frame-0…4.png`, renamed from
  `cat-frame-0…4.png`) and the menu bar animation (RunnerLayer, BackgroundLayer, the CPU → speed rule),
  ported to `NotchAI/SystemMonitor/RunCatStatusItem.swift`.
- Changed for NotchAI (2026-11-09): only the cat; an `NSStatusItem` instead of a SwiftUI `MenuBarExtra`;
  the menu bar's height and the screen's scale instead of fixed 22 pt / 2×; the speed comes from
  NotchAI's shared `SystemMonitor`; a click opens the notch instead of RunCat's dashboard. The changed
  file states this in its header.
- Licence text: `NotchAI/Resources/RunCat/RunCatNeo-LICENSE.txt` (also inside the app bundle).
  RunCat Neo ships no NOTICE file.

## SystemInfoKit — Apache License 2.0

- Source: https://github.com/Kyome22/SystemInfoKit (7.2.2), the measuring library RunCat Neo uses
- Copyright 2020 Takuto Nakamura
- Used: the CPU-usage and memory-usage arithmetic, ported to `NotchAI/SystemMonitor/SystemSampler.swift`.
- Changed for NotchAI (2026-11-09): pure, tested functions; the network rate counts only the primary
  interface, survives the 32-bit counters wrapping and divides by the real elapsed time; memory
  pressure from the kernel. The changed file states this in its header.
- Licence text: the same Apache 2.0 text as above.

## Stats — MIT License

- Source: https://github.com/exelban/stats (3.0.22, commit `1a4a9a6`)
- Copyright (c) 2019 Serhiy Mytrovtsiy
- Used: which SMC keys are CPU core temperature sensors on each Apple Silicon generation, and the
  「Hottest CPU」 rule (highest core sensor, readings outside 10–120 °C ignored), in
  `NotchAI/SystemMonitor/SMCTemperature.swift`. No Stats code is copied; the SMC reader is NotchAI's own.

## mediaremote-adapter — BSD 3-Clause

See `Vendor/mediaremote-adapter/LICENSE`.

## whisper.cpp — MIT

Bundled with 강의녹음 and NotchDesk; see `build/whisper/whisper-LICENSE` when built.
