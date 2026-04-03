# LSTN2 Installation Guide

Step-by-step guide to install and set up LSTN2 on your Mac. The app is signed with an Apple Developer ID.

## Prerequisites

| Requirement | Why |
|---|---|
| **macOS 14.2+** (Sonoma or later) | System audio capture uses Core Audio Taps, available from macOS 14.2 |
| **OpenAI API key** | Powers transcription, question detection, and RAG answers |

> Python and uv are also required but the setup wizard installs them for you.

## Step 1 — Install the App

Download the latest `LSTN2.app` from the [Releases](https://github.com/nimrodhr/Listen2/releases) page.

1. Move **LSTN2.app** to your **Applications** folder.
2. Launch LSTN2.

<details>
<summary>Building from source (for developers)</summary>

Requires Xcode 16+:

```bash
git clone https://github.com/nimrodhr/Listen2.git
cd Listen2
open LSTN2/LSTN2.xcodeproj
```

Press **Cmd+R** to build and run.

</details>

## Step 2 — Setup wizard

On first launch the setup wizard appears automatically.

## Step 3 — Environment

The first screen installs three components:

| Component | What it does |
|---|---|
| **uv** | Fast Python package manager (installed to `~/.local/bin/uv`) |
| **Python 3.13** | Managed by uv — does not affect any existing Python on your system |
| **Backend libraries** | Installed inside the project's `.venv` folder (nothing installed globally) |

Click **Install All** and wait for all three checkmarks to turn green.

If a step fails, a **Retry** button appears for that specific step. You can also expand the info panel (ℹ button) next to each component to see exactly what it does and where it's installed.

A terminal output pane at the bottom shows real-time progress.

Once all three components show green checkmarks and "Environment is ready" appears, click **Next**.

## Step 4 — API Key

1. Go to [platform.openai.com/api-keys](https://platform.openai.com/api-keys) and create a new API key
2. Paste the key into the secure input field (it starts with `sk-`)
3. Click **Save API Key**

The key is stored securely in the **macOS Keychain** (encrypted at rest). It never leaves your machine except when sent directly to OpenAI's API over HTTPS.

Once the green "API key saved" confirmation appears, click **Next**.

> You can skip this step and add the key later in Settings, but recording will not work without it.

### What the API key is used for

- **Real-time transcription** — OpenAI Realtime API converts speech to text
- **Question detection** — GPT identifies questions in the conversation
- **RAG answers** — GPT generates answers from your knowledge base
- **Cost** — OpenAI charges per usage. You control spending via your OpenAI account dashboard

## Step 5 — Audio Config

This is an informational screen. No action is required.

- **Microphone**: Select your preferred mic in Settings after the wizard completes
- **System audio**: Captured automatically via native macOS APIs (Core Audio Taps) — no virtual audio drivers or extra software needed

Click **Finish** to complete the setup.

## Step 6 — Grant permissions

When you click Finish, macOS may prompt you to grant **Screen & System Audio Recording** permission. This is required for system audio capture.

If the prompt does not appear automatically, go to:

**System Settings > Privacy & Security > Screen & System Audio Recording** and enable LSTN2.

When you start your first recording, macOS will also prompt for **Microphone** access. Grant it.

## Step 7 — Start using LSTN2

After the wizard completes, the main app window opens. The backend launches automatically and connects via WebSocket — you'll see a green connection badge when ready.

1. Select your microphone in **Settings** (gear icon)
2. Click the **Record** button to start a session
3. LSTN2 will transcribe both your mic and system audio in real time

## Post-setup

### Re-running the setup wizard

Go to **Settings > Re-run Setup Wizard** at any time to verify your environment or reinstall components.

### Changing your API key

Go to **Settings** and update the API key field. The new key is saved to the Keychain immediately.

### Adding documents to the knowledge base

Switch to the **Knowledge Base** panel and upload documents (PDF, TXT, MD, DOCX). These are chunked, embedded, and stored locally in ChromaDB at `~/.listen/chromadb/`.

### Running the backend manually

If you prefer to run the backend outside of the app:

```bash
cd backend
uv sync                         # Install/sync dependencies
uv run python -m listen.main    # Start WebSocket server on ws://127.0.0.1:8765
```

### Running tests

```bash
# Backend (Python)
cd backend
pytest

# Frontend (Swift) — in Xcode
# Press Cmd+U to run the LSTN2Tests target
```

## Troubleshooting

### "uv not found" or "Python not available"

Re-run the setup wizard from Settings. It will detect what's missing and let you reinstall.

### Backend won't start

Check that port 8765 is free:

```bash
lsof -i :8765
```

LSTN2 uses a single-instance guard. If a stale process is occupying the port, the app will attempt to kill it (only if it's a Python/uv process). You can also kill it manually:

```bash
kill $(lsof -ti :8765)
```

### No system audio / "Permission required"

Go to **System Settings > Privacy & Security > Screen & System Audio Recording** and make sure LSTN2 is enabled. You may need to restart the app after granting permission.

### No microphone audio

Go to **System Settings > Privacy & Security > Microphone** and make sure LSTN2 is enabled. Also verify you've selected the correct mic in LSTN2's Settings panel.

### WebSocket connection fails

The backend generates a per-session auth token at `~/.listen/ws_token`. If the file is missing or stale, restart the app (Quit from the menu bar, then relaunch). The token is regenerated on each backend launch.

## Data locations

All data is stored under `~/.listen/`:

| Path | Purpose |
|---|---|
| `settings.json` | Config (models, audio devices, thresholds) |
| `chromadb/` | Knowledge base vector store |
| `transcripts/` | Saved transcript sessions |
| `activity.jsonl` | Activity log (24-hour retention) |
| `backend.pid` | Single-instance guard |
| `backend.lock` | Advisory file lock |
| `ws_token` | Per-session WebSocket auth token |
| `rag_queries.jsonl` | RAG query analytics |

> The API key is stored in the macOS Keychain, not in any of these files.
