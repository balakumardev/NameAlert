# Takeheed

Takeheed is a macOS menu-bar app that alerts you the moment someone says your name or keyword during calls, meetings, or videos.

Speech transcription runs on your Mac, and your audio never leaves it. Takeheed is free, requires no account, and includes no analytics or advertisements.

Pro, an optional one-time in-app purchase, adds unlimited rules and the alerts that reach your phone (ntfy, Telegram, webhook).

## Features

- **Keyword rules**: Add custom keywords and phrases with spelling or nickname variants (such as "Bala, Balakumar, BK").
- **Sensitivity controls**: Choose Exact, Balanced, or Loose matching per rule. Balanced catches small pronunciation variations while ignoring similar everyday words.
- **Multiple alert channels**:
  - System sound alert.
  - macOS notification with Snooze and Open History actions.
  - Persistent alarm that continues ringing until dismissed.
  - Visual screen flash.
  - Push notification to your phone via ntfy (Pro).
  - Phone call to your phone via Telegram using CallMeBot (Pro).
  - Signed JSON webhook for Slack, Home Assistant, Zapier, or n8n (Pro).
- **Transcript context**: Each alert includes the last ~30 seconds of transcript so you know what was asked.
- **Listening modes**: Listen continuously, or listen only when on an active call by detecting when another app accesses the microphone.
- **Snooze**: Snooze alerts for 15 minutes, 1 hour, or until tomorrow.
- **Searchable history**: Review past mentions locally on your Mac, or turn off history recording entirely.
- **Live transcript window**: View speech recognition output in real time.
- **Shortcuts and Siri**: Actions to start, pause, toggle, snooze, add keywords, and view recent mentions.
- **URL scheme**: Control the app using `takeheed://` commands: `start`, `pause`, `toggle`, `resume`, `snooze?minutes=30`, `open/settings`, `open/history`, and `open/live`.

## Requirements

- macOS 14 Sonoma or later.
- Apple silicon or Intel processor.
- System permissions:
  - **Screen & System Audio Recording**: Required to capture audio from calls and media via ScreenCaptureKit. Takeheed never captures or stores screen video.
  - **Microphone**: Optional, for listening to people speaking in the room.
  - **Speech Recognition**: Required only on older macOS versions that rely on Apple's older speech recognizer.
  - **Notifications**: Optional, to display banner alerts.

## Installation

Install it from the [Mac App Store](#app-store).

## Privacy

- Audio never leaves your Mac.
- The words around a mention leave only if you set up ntfy, a Telegram call (CallMeBot) or a webhook, and only to the service you chose.
- Transcription uses on-device speech recognition, or a small local model on Macs without it. The model is downloaded once from huggingface.co.
- No user accounts, no tracking, and no analytics.
- The only network connections are that model download and the alert services you set up.
- Secrets and tokens are saved in the macOS Keychain.

## Building from Source

Prerequisites:
- Xcode 26 or later.
- XcodeGen. CI pins XcodeGen 2.46.0, and `brew install xcodegen` works with 2.44 or later.

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

### Testing the Pro purchase locally

Only the Mac App Store build sells Pro (`APP_STORE_BUILD`, set by `scripts/build_appstore.sh`; `scripts/check_purchase_mode.sh` checks each build, and an Xcode archive without the flag stops with an error). Other builds sell nothing and have every feature on. To try the purchase in a Debug run, open the NameAlert scheme in Xcode, tick `-EnforcePro YES` under Edit Scheme > Run > Arguments, and run: the scheme serves the product from `Pro.storekit`. Debug > StoreKit > Manage Transactions refunds or deletes the test purchase.

## Project Structure

The folders, targets, modules and bundle ID keep the app's earlier name, NameAlert.

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

- `ci.yml`: Runs on every push and pull request. On GitHub's Xcode 27 preview image (`xcode-27`) it runs the package tests, builds a universal Release app with no warnings allowed in our sources, and runs the Screenshots scheme tests. The package tests also run on macOS 26 and macOS 15 (Xcode 26) and on an Intel Mac.
- `appstore.yml`: Uploads builds to App Store Connect from `main`. On `v*` tags it also syncs the listing text, uploads the screenshots, sets the App Review details and submits for review. It does not submit while the Pro in-app purchase is not yet approved: the first submission with it is made on the App Store Connect website.
- `release.yml`: Runs only by hand, since the app ships on the Mac App Store: on a `v*` tag it runs the package tests, then builds, notarizes (the app, then the disk image) and publishes a DMG release.
- `pages.yml`: Deploys the static site to GitHub Pages.
- Workflows that use secrets never run on pull requests, and install `xcodegen` and `asc` at pinned versions checked against a SHA-256.

## Acknowledgements

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT License)
- [Whisper](https://github.com/openai/whisper) model weights, OpenAI (MIT License)
- [Silero VAD](https://github.com/snakers4/silero-vad), Silero Team (MIT License)
- SCOWL word lists

## License

This project is licensed under the MIT License.
