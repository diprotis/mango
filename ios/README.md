# Mango — iOS app

A native SwiftUI + SwiftData reading companion that turns any book into a
gamified learning journey. Works fully offline; no third-party dependencies.

## Requirements

- macOS with **Xcode 16 or newer** (the project uses Xcode 16 file-system-
  synchronized groups).
- Targets **iOS 17+**.

## Open and run

```bash
open Mango.xcodeproj
```

Pick an iPhone simulator (e.g. *iPhone 16*) and press **Run** (⌘R). The app opens
into onboarding, then a home screen with a bundled public-domain sample book and a
ready-made gamified journey. It is usable with **no API key and no backend** —
roadmaps and grading fall back to an on-device generator (`MockAIService`).

## Run the tests

Press **⌘U** in Xcode, or from the repo root:

```bash
make ios-test
```

(Runs `xcodebuild test` on a simulator against the `Mango` scheme /
`MangoTests` target.)

## XcodeGen fallback

A pre-generated `Mango.xcodeproj` is committed so you can open it directly. If it
ever drifts or won't open, regenerate it from `project.yml`:

```bash
brew install xcodegen && xcodegen generate
```

## AI key / backend URL

Both are configured at runtime in **Settings → AI engine**:

- **Direct Claude API** — paste an `sk-ant-…` key (stored in the Keychain, never
  in source). Roadmaps and reflection grading then call Claude on-device. Testing
  only — the key lives on the device.
- **Mango Backend** — enter the deployed API base URL. (Note: calling the deployed
  backend needs Cognito sign-in, which is on the roadmap.)
- **Automatic** uses the backend if set, else a Claude key, else offline mock.

## Folder layout

```
Mango/
├── App/           # MangoApp, AppModel container, RootView, MainTabView, Route
├── DesignSystem/  # Theme, Typography, Components, Haptics, Color helpers
├── Models/        # SwiftData @Model types + enums + catalogs
├── Services/      # AI, Networking, Content connectors, Persistence,
│                  #   Gamification, Notifications
└── Features/      # Onboarding, Home (Today), Library, Reader, Journey,
                   #   Lesson, Profile, Settings
MangoTests/        # XCTest unit tests
project.yml        # XcodeGen spec (optional)
```

See [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) and
[../docs/DESIGN_SYSTEM.md](../docs/DESIGN_SYSTEM.md) for details.
