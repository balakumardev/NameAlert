# Takeheed App Review Notes

## General Information
Takeheed is a macOS menu-bar utility that alerts users when their name or chosen keywords are spoken during meetings, calls, or video playback.
- Menu-bar app: Takeheed lives in the macOS menu bar (ear icon). There is no Dock icon and no main window after completing initial setup.
- Initial setup: On first launch, a setup window appears to configure a name and optional permissions.
- No account or login: Takeheed needs no account or sign-in, also not to buy Pro.
- On-device processing: All speech transcription and keyword matching run on the Mac. Audio never leaves the Mac. The words around a mention leave only if the user sets up an ntfy, Telegram call or webhook alert, and only to the service they chose.

## In-App Purchase (Pro)
- One non-consumable, "Pro (Lifetime)" (dev.balakumar.namealert.pro): a one-time purchase, USD 4.99 in the U.S. store. The Buy button shows the App Store's price.
- Free: up to 3 rules (setup's name rule plus 2 more, any number of words each), every alert on the Mac (Sound, Notification, Alarm until dismissed, Screen flash), History, Shortcuts and the takeheed:// URL scheme.
- Pro adds unlimited rules and the alerts that leave the Mac: ntfy push, Telegram call (CallMeBot) and webhook, with their Test buttons.
- Where: the ear icon in the menu bar → Settings… → Pro (sidebar): Buy Pro, Restore Purchases, Terms of Use, Privacy Policy. The same sheet opens from Rules → + at 3 rules, and from "Unlock Pro…" next to ntfy push, Telegram call or Webhook.
- Sandbox test: Settings → Pro → Buy Pro with the sandbox Apple Account; Pro turns on at once. Restore Purchases is on the same screen.
- A Pro alert without an account: after buying, set any ntfy topic in Settings → Alerts, open https://ntfy.sh/<topic> and click Test.
- After a refund nothing is deleted: rules past the third and the phone and webhook alerts wait until Pro is back.

## Permissions Requested
- Screen & System Audio Recording: Used only to receive system audio from calls and videos via Apple's ScreenCaptureKit framework. Takeheed never records, captures, or saves screen content. The video stream is configured to a 2x2 pixel buffer that is immediately discarded.
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
5. Test the purchase: Settings → Pro → Buy Pro. Rules → + then adds a fourth rule, and ntfy push can be chosen.

## Additional Notes
- Network requests: the app makes three kinds. (1) When a local speech model is needed, it is downloaded once from huggingface.co (a file of 32 to 60 MB; the request only asks for the file). It is needed when Apple's on-device speech is not available for the user's language, or when the user chooses it in Settings → Speech. (2) An alert goes to a webhook, ntfy topic or CallMeBot only if the user sets it up in Settings → Alerts. (3) Once a day (and when the user chooses Check for Updates in the menu bar window or Settings → About) it asks Apple's public lookup service, https://itunes.apple.com/lookup?bundleId=dev.balakumar.namealert, for the newest version: a GET with no body, cookies or identifiers. If a newer version is out, an alert offers Update, which only opens the Mac App Store page (nothing is downloaded or installed by the app), Remind Me Later or Skip This Version. The daily check can be turned off in Settings → About. There are no other network requests: no accounts, no analytics, no ads. Buying Pro goes through StoreKit; the app sends purchase data nowhere.
