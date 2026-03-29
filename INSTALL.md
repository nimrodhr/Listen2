# LSTN2 Installation Guide

## Requirements

- macOS 14.2+ (Sonoma or later — required for native system audio capture)
- An OpenAI API key ([get one here](https://platform.openai.com/api-keys))

Everything else (Python, backend dependencies) is installed automatically by the app's setup wizard. System audio capture uses native macOS APIs — no third-party audio drivers needed.

---

## Step 1 — Install the App

1. Open the **LSTN2.dmg** file. A Finder window will appear showing the LSTN2 app and an Applications folder shortcut.
2. Drag **LSTN2.app** into the **Applications** folder.
3. Eject the DMG (right-click the mounted volume on the desktop or sidebar and choose Eject).

## Step 2 — Approve the App in macOS Security

LSTN2 is not signed with an Apple Developer ID, so macOS will block it on first launch.

1. Open **LSTN2** from your Applications folder. macOS will show a dialog saying the app "can't be opened because Apple cannot check it for malicious software."
2. Click **Done** (or **OK**) to dismiss the dialog.
3. Go to **System Settings > Privacy & Security**.
4. Scroll down to the **Security** section. You'll see a message: *"LSTN2" was blocked from use because it is not from an identified developer.*
5. Click **Open Anyway**.
6. macOS will ask one more time — click **Open** to confirm.

The app will now launch normally. You only need to do this once.

## Step 3 — Setup Wizard

On first launch, LSTN2 opens a setup wizard that installs everything the app needs. Follow the three steps:

### 3a — Environment

This step checks for and installs:

- **uv** — a fast Python package manager (installed to `~/.local/bin/uv`)
- **Python 3.13** — managed by uv, separate from any existing Python on your system
- **Backend dependencies** — installed into the project's own `.venv` folder (nothing installed globally)

Click **Install All** and wait for each item to show a green checkmark.

### 3b — API Key

Paste your OpenAI API key and click **Save API Key**. The key is stored locally at `~/.listen/settings.json` and is only sent to OpenAI's API over HTTPS.

You can skip this step and add the key later in the Settings tab.

### 3c — Audio Configuration

This step explains that you'll need to select your microphone in **Settings** after the wizard finishes (the device list is provided by the backend, which starts after setup).

System audio is captured automatically via native macOS Core Audio Taps — no additional configuration needed.

Click **Finish** to complete setup.

## Step 4 — Configure Microphone

After the wizard completes and the backend connects (green "Connected" badge in the top-left):

1. Click the **gear icon** in the top bar to open Settings.
2. Under **Audio Devices**, select your preferred **Microphone**.
3. Click **Save**.

## Step 5 — Grant Permissions

When you start your first recording, macOS will prompt for permissions:

- **Microphone** — a system dialog will appear: *"LSTN2" would like to access the microphone.* Click **Allow**.
- **System Audio** — macOS will prompt you to allow screen/audio capture. Click **Allow** to enable system audio recording via Core Audio Taps.

If you accidentally deny either permission, you can re-enable them later in **System Settings > Privacy & Security > Microphone** (and **Screen & System Audio Recording**).

## Step 6 — Start Recording

1. Click the **Record** button in the top-right corner.
2. The Live tab shows real-time transcription and detected questions.
3. Click **Stop** when done.

---

## Troubleshooting

**"LSTN2 can't be opened"**
Follow Step 2 above — go to System Settings > Privacy & Security > Open Anyway.

**Backend won't connect (red "Disconnected" badge)**
The backend starts automatically. If it fails, try re-running the setup wizard from Settings > Re-run Setup Wizard. Check that port 8765 isn't in use by another process.

**No audio devices listed in Settings**
Click the **Refresh Devices** button in the bottom-right of the Settings tab. Ensure the backend is connected (green badge).

**Microphone permission denied**
Go to System Settings > Privacy & Security > Microphone and enable LSTN2.

**System audio not captured**
Go to System Settings > Privacy & Security > Screen & System Audio Recording and enable LSTN2. Requires macOS 14.2 or later.

**Setup wizard skipped but something is missing**
Go to Settings > Re-run Setup Wizard to check and re-install prerequisites.

---

## Uninstalling

1. Quit LSTN2 (right-click the menu bar icon > Quit, or Cmd+Q).
2. Delete **LSTN2.app** from your Applications folder.
3. Optionally remove app data: `rm -rf ~/.listen`
4. Optionally remove uv and its managed Python installs: `rm -rf ~/.local/bin/uv ~/.local/share/uv`
