# LSTN2

A macOS meeting co-pilot that provides real-time transcription, automatic question detection, and context-aware Q&A — powered by OpenAI and a local knowledge base.

## Features

- **Live Transcription** — Dual-stream capture (microphone + native system audio via Core Audio Taps) with real-time speaker-labeled transcription via OpenAI Realtime API
- **Automatic Question Detection** — Identifies questions in conversation, categorized by type (factual, opinion, clarification, action item)
- **RAG-Powered Answers** — Answers detected questions using your knowledge base with source citations (hybrid vector + BM25 search with reranking)
- **Knowledge Base** — Ingest documents (PDF, TXT, MD, DOCX) into a local ChromaDB vector store
- **Transcript Persistence** — Sessions saved to disk with export support
- **Activity Log** — Event tracking with 24-hour retention
- **Menu Bar Access** — Quick toggle via the LSTN2 menu bar icon
- **Guided Setup Wizard** — Step-by-step first-run wizard that installs prerequisites, configures audio, and validates the environment. Re-runnable from Settings.

## Architecture

```
┌─────────────────────┐     WebSocket (8765)     ┌──────────────────────┐
│   SwiftUI Frontend  │ ◄──────────────────────► │   Python Backend     │
│                     │   command.* / event.*     │                      │
│  AppState           │                          │  Audio Capture       │
│  WebSocketClient    │                          │  OpenAI Realtime     │
│  EventRouter        │                          │  Question Detection  │
│  PythonManager      │                          │  RAG Engine (KB)     │
└─────────────────────┘                          └──────────────────────┘
```

The **SwiftUI frontend** handles UI and state management. The **Python backend** runs async pipelines for audio capture, transcription, intelligence, and knowledge base operations. They communicate over a local WebSocket using a typed `command.*` / `event.*` protocol.

## Requirements

- macOS 14.2+ (Sonoma or later — required for Core Audio Taps)
- Xcode 16+
- OpenAI API key

> The setup wizard automatically installs [uv](https://docs.astral.sh/uv/), Python 3.13, and backend dependencies. System audio capture works natively — no third-party audio drivers needed.

## Setup

1. **Clone the repo:**
   ```bash
   git clone https://github.com/nimrodhr/Listen2.git
   cd Listen2
   ```

2. **Run the app** — Open `LSTN2/LSTN2.xcodeproj` in Xcode and press Cmd+R.

3. **Follow the Setup Wizard** — On first launch, a guided wizard walks you through:
   - **Environment** — Installs `uv`, Python 3.13, and backend dependencies
   - **API Key** — Enter your OpenAI API key (can be skipped and added later in Settings)
   - **Audio Config** — Select your microphone in Settings. System audio is captured automatically via native macOS APIs (you'll be prompted to grant permission on first recording).

   The wizard detects what's already installed and skips completed steps. You can re-run it anytime from **Settings > Re-run Setup Wizard**.

## Running the Backend Manually

```bash
cd backend
uv run python -m listen.main   # Starts WebSocket server on ws://127.0.0.1:8765
```

## Testing

```bash
cd backend
pytest                                    # All tests
pytest tests/test_transcript_store.py -v  # Single test file
```

## Project Structure

```
LSTN2/LSTN2/                   # SwiftUI frontend
├── LSTN2App.swift             # App entry point, lifecycle, wizard flow
├── ContentView.swift          # Main window with panel navigation
├── State/
│   ├── AppState.swift         # @Observable app state
│   └── SetupState.swift       # Setup wizard state & persistence
├── Services/
│   ├── WebSocketClient.swift  # WS connection with reconnect
│   ├── EventRouter.swift      # Event parsing & state updates
│   ├── PythonManager.swift    # Backend subprocess management
│   ├── SetupManager.swift     # Prerequisite checks & installation
│   ├── SystemAudioCapture.swift # System audio via Core Audio Taps (macOS 14.2+)
│   └── AudioDeviceService.swift # Audio device enumeration
├── Views/
│   ├── Setup/                 # Setup wizard UI
│   │   ├── SetupWizardView.swift
│   │   ├── StepProgressBar.swift
│   │   └── Steps/             # Per-step views (Environment, API Key, Audio)
│   ├── SettingsView.swift     # Settings panel with re-run wizard button
│   └── ...                    # Transcript, Questions, KB, Activity views
└── Models/Protocol.swift      # WebSocket protocol types

backend/                       # Python backend
├── src/listen/
│   ├── main.py                # Entry point, PID guard
│   ├── config.py              # Pydantic settings schema
│   ├── server/                # WebSocket server, command routing
│   ├── audio/                 # Microphone capture, resampling
│   ├── transcription/         # OpenAI Realtime sessions, persistence
│   ├── intelligence/          # Question detection, RAG engine, LLM client
│   └── knowledge/             # ChromaDB vector store, document ingestion
└── tests/
```

## Data

All persisted data lives under `~/.listen/`:

| File | Purpose |
|------|---------|
| `settings.json` | Config (API keys, models, audio devices, thresholds) |
| `activity.jsonl` | Activity log with 24-hour retention |
| `chromadb/` | Vector store |
| `transcripts/` | Saved transcript sessions |
| `backend.pid` | Single-instance guard |
| `ws_token` | Per-session WebSocket auth token (deleted on exit) |
| `rag_queries.jsonl` | RAG query analytics |

## Security

- **Per-session WebSocket auth** — The backend generates a random 64-character token on startup, written to `~/.listen/ws_token` (owner-only permissions). The frontend reads this token and presents it on every WebSocket connection. Connections without a valid token are rejected.
- **CSWSH protection** — WebSocket connections with an `Origin` header (i.e., from browsers) are rejected, preventing cross-origin WebSocket hijacking attacks from malicious web pages.
- **Sanitized error responses** — Internal exception details are never sent to the frontend; only generic error messages are returned over the WebSocket.
- **Process verification** — Stale process cleanup verifies the process is actually a Python/uv backend before terminating, preventing accidental kills of unrelated services on port 8765.

## License

This project is for personal use.
