# Run Mango on your iPhone

Build and run the app on a **physical iPhone** from your Mac. The app works fully
offline (no backend, no API key needed), so this is everything you need to feel it.

## Prerequisites
- A Mac with **Xcode 16 or newer**.
- An **iPhone on iOS 17.0+**.
- A cable (USB‑C / Lightning). The first install is easiest over cable; wireless works after.
- An **Apple ID**. A free Apple ID is enough for testing — note: free‑account apps expire
  after **7 days** (just re‑run to refresh) and you can sideload up to 3 apps. A paid Apple
  Developer Program account ($99/yr) removes the limit and unlocks TestFlight.

## One‑time Mac setup
1. Open **Xcode → Settings (⌘,) → Accounts → “+” → Apple ID** and sign in.

## Steps
1. Open the project: `open ios/Mango.xcodeproj` (or `make ios-open`).
2. In the left sidebar pick the **Mango** project → **Mango** target → **Signing & Capabilities**:
   - Tick **Automatically manage signing**.
   - **Team:** choose your Apple ID (it'll say “Personal Team”).
   - If you get *“Failed to register bundle identifier”* / *“not available”*, change the
     **Bundle Identifier** to something unique, e.g. `com.<yourname>.Mango`.
3. Plug in the iPhone. If the phone asks, tap **Trust** and enter your passcode.
4. In Xcode's toolbar, open the run‑destination dropdown and select your iPhone (under
   **iOS Device**). If it says “Preparing…”, wait for it to finish copying symbols.
5. Press **Run (⌘R)**. Xcode builds, installs, and launches the app.
6. **First launch only** — iOS blocks untrusted developer apps:
   - On the iPhone: **Settings → General → VPN & Device Management → Developer App →**
     tap your Apple ID → **Trust**.
   - Back in Xcode, press **Run (⌘R)** again.
7. The app opens onboarding → a home screen with the bundled sample book (*Meditations*)
   and a ready gamified journey. Do a lesson to see XP, the streak, and badges. All offline.

## Optional — turn on real AI, on device
Profile tab → gear (Settings) → **AI engine → Direct Claude API** → paste an `sk‑ant‑…`
key (stored in the iPhone Keychain). Roadmaps and reflection grading now come from Claude.
Leave it on **Automatic / Offline** to stay fully local.

## Optional — point at your AWS backend
After deploying (see [DEPLOY.md](DEPLOY.md)): Settings → **AI engine → Mango Backend** →
paste the API URL. Note: backend mode needs Cognito sign‑in, which isn't built yet
(see [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md)), so for on‑device testing use Direct‑Claude
or Offline for now.

## Run wirelessly (after the first cable install)
Xcode → **Window → Devices and Simulators** → select your iPhone → tick **Connect via
network**. You can now run without the cable on the same Wi‑Fi.

## Troubleshooting
- **iPhone not in the device list:** unlock it, tap **Trust**, try another cable/port; confirm iOS ≥ 17.
- **“Untrusted Developer” on launch:** do Step 6 (trust the developer profile on the phone).
- **Signing error / bundle id taken:** set your **Team** and change the **Bundle Identifier** (Step 2).
- **App stopped working after ~7 days (free account):** re‑run from Xcode (⌘R) to re‑sign;
  upgrade to the paid program to remove the limit.
- **“Could not launch … device locked”:** keep the phone unlocked during install.
- **Build can't find SDK/tools:** Xcode → Settings → Locations → set **Command Line Tools**
  to your Xcode 16 install.
