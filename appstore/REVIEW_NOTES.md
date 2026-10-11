# NameAlert App Review Notes

## General Information
NameAlert is a macOS menu-bar utility that alerts users when their name or chosen keywords are spoken during meetings, calls, or video playback.
- Menu-bar app: NameAlert lives in the macOS menu bar (ear icon). There is no Dock icon and no main window after completing initial setup.
- Initial setup: On first launch, a setup window appears to configure a name and optional permissions.
- No account or login: NameAlert requires no account, sign-in, subscription, or in-app purchase.
- On-device processing: All speech transcription and keyword matching run on the Mac. Audio never leaves the Mac. The words around a mention leave only if the user sets up an ntfy, Telegram call or webhook alert, and only to the service they chose.

## Permissions Requested
- Screen & System Audio Recording: Used only to receive system audio from calls and videos via Apple's ScreenCaptureKit framework. NameAlert never records, captures, or saves screen content. The video stream is configured to a 2x2 pixel buffer that is immediately discarded.
- Microphone: Optional. Used to listen to people speaking in the room.
- Speech Recognition: Requested only on older macOS versions that rely on Apple's older on-device speech recognizer.
- Notifications: Optional. Used to deliver local notifications when a keyword is matched.

## How to Test in 2 Minutes
1. Complete the first-launch setup window using any name, such as "Taylor".
2. Test audio detection using one of the following methods:
   - Terminal: Run the command: say "Hey Taylor, can you share your screen"
   - Video playback: Play any video or audio clip that contains the test name.
3. Test rule matching in Settings:
   - Click the ear icon in the menu bar and select Settings.
   - Go to Rules and use the "Try a sentence" field to test keyword detection on sample text.
4. Test alert channels:
   - In Settings, open the Alerts tab.
   - Click the Test button next to any alert channel (Sound, Notification, Screen Flash) to verify delivery.

## Additional Notes
- No in-app purchases or paid features exist in this app.
- Network requests: the app makes two kinds. (1) When a local speech model is needed, it is downloaded once from huggingface.co (a file of 32 to 60 MB; the request only asks for the file). It is needed when Apple's on-device speech is not available for the user's language, or when the user chooses it in Settings → Speech. (2) An alert goes to a webhook, ntfy topic or CallMeBot only if the user sets it up in Settings → Alerts. There are no other network requests: no accounts, no analytics, no ads.
