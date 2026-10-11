# NameAlert

NameAlert is a macOS menu-bar app that alerts you the moment someone says your name or keyword during calls, meetings, or videos.

Speech transcription runs entirely on your Mac, so audio and transcripts stay private. NameAlert is free, requires no account, and includes no analytics or advertisements.

## Features

- **Keyword rules**: Add custom keywords and phrases with spelling or nickname variants (such as "Bala, Balakumar, BK").
- **Sensitivity controls**: Choose Exact, Balanced, or Loose matching per rule. Balanced catches small pronunciation variations while ignoring similar everyday words.
- **Multiple alert channels**:
  - System sound alert.
  - macOS notification with Snooze and Open History actions.
  - Persistent alarm that continues ringing until dismissed.
  - Visual screen flash.
  - Push notification to your phone via ntfy.
  - Phone call to your phone via Telegram using CallMeBot.
  - Signed JSON webhook for Slack, Home Assistant, Zapier, or n8n.
- **Transcript context**: Each alert includes the last ~30 seconds of transcript so you know what was asked.
- **Listening modes**: Listen continuously, or listen only when on an active call by detecting when another app accesses the microphone.
- **Snooze**: Snooze alerts for 15 minutes, 1 hour, or until tomorrow.
- **Searchable history**: Review past mentions locally on your Mac, or turn off history recording entirely.
- **Live transcript window**: View speech recognition output in real time.
- **Shortcuts and Siri**: Actions to start, pause, toggle, snooze, add keywords, and view recent mentions.
- **URL scheme**: Control the app using `namealert://` commands: `start`, `pause`, `toggle`, `resume`, `snooze?minutes=30`, `open/settings`, `open/history`, and `open/live`.

## Requirements

- macOS 14 Sonoma or later.
- Apple silicon or Intel processor.
- System permissions:
  - **Screen & System Audio Recording**: Required to capture audio from calls and media via ScreenCaptureKit. NameAlert never captures or stores screen video.
  - **Microphone**: Optional, for listening to people speaking in the room.
  - **Speech Recognition**: Required only on older macOS versions that rely on Apple's older speech recognizer.
  - **Notifications**: Optional, to display banner alerts.

## Installation

- Install from the [Mac App Store](#app-store).
- Or download the notarized DMG from [GitHub Releases](https://github.com/balakumardev/NameAlert/releases/latest).

## Privacy

- Audio and transcripts never leave your Mac.
- Transcription uses on-device speech recognition, or a small downloadable local model on Macs without it.
- No user accounts, no tracking, and no analytics.
- External connections occur only if you configure an optional alert service (ntfy, CallMeBot, or custom webhook).
- Secrets and tokens are saved in the macOS Keychain.

## Building from Source

Prerequisites:
- Xcode 15 or later.
- XcodeGen.

```bash
# Install XcodeGen
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Build the app
xcodebuild -scheme NameAlert

# Or open in Xcode
open NameAlert.xcodeproj

# Run tests
swift test --package-path Packages/NameAlertKit
```

## Project Structure

- `NameAlert/`: App shell including menu bar items, onboarding flow, settings windows, and App Intents.
- `Packages/NameAlertKit/`: Modular package containing core functionality:
  - `NameAlertCore`: Configuration, rule definition, matching logic, and mention history.
  - `NameAlertAudio`: Audio stream capture, mixing, and microphone call detection.
  - `NameAlertSpeech`: Speech recognition engines (Apple Speech frameworks and whisper.cpp engine) and model downloads.
  - `NameAlertAlerts`: Alert dispatch channels (sound, notification, alarm, flash, ntfy, CallMeBot, webhook).
  - `NameAlertRuntime`: Central listening and coordination controller.
- `scripts/`: Packaging and release scripts.
- `appstore/`: App Store Connect metadata and review notes.
- `site/`: Static website and documentation.

## CI Overview

- `ci.yml`: Runs automated tests on every push.
- `appstore.yml`: Uploads builds to App Store Connect from `main` and submits for review on `v*` tags.
- `release.yml`: Builds, notarizes, and publishes DMG releases on `v*` tags.
- `pages.yml`: Deploys the static site to GitHub Pages.

## Acknowledgements

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT License)
- SCOWL word lists

## License

This project is licensed under the MIT License.
