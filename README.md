# ScreenX

Native macOS-Screenshot-App für die Menüleiste (Swift 6, SwiftUI + AppKit, macOS 26).

## Entwicklung

1. XcodeGen installieren: `brew install xcodegen`
2. `Local.xcconfig.example` nach `Local.xcconfig` kopieren und `DEVELOPMENT_TEAM` (Team-ID des Apple Personal Teams) eintragen.
3. Projekt erzeugen: `xcodegen generate`
4. `ScreenX.xcodeproj` in Xcode öffnen.

Tests: `xcodebuild test -scheme ScreenXCore -destination 'platform=macOS'`
