# LSTN2

A macOS meeting co-pilot that provides real-time transcription, question detection, and context-aware Q&A powered by OpenAI and a local knowledge base. Signed and notarized by Apple.

## Architecture

**macOS app (SwiftUI)** communicates over WebSocket with a **Python backend** that handles transcription and intelligence. Both mic and system audio are captured natively in Swift and streamed as tagged binary frames.

```
┌─────────────────────┐     WebSocket (8765)     ┌──────────────────────┐
│   SwiftUI Frontend  │ ◄──────────────────────► │   Python Backend     │
│                     │  text: command.*/event.*  │                      │
│  AppState (@Observable)  binary: tagged audio  │  OpenAI Realtime     │
│  WebSocketClient                               │  Question Detection  │
│  EventRouter                                   │  RAG Engine (KB)     │
│  SystemAudioCapture                            │  Activity Logging    │
│  MicAudioCapture                               │                      │
│  PythonManager                                 │                      │
│  SetupManager                                  │                      │
│  KeychainManager                               │                      │
└─────────────────────┘                          └──────────────────────┘
```

**Audio capture**: System audio is captured natively in Swift via `AudioHardwareCreateProcessTap` (Core Audio Taps, macOS 14.2+). Mic audio is captured in Swift via `AVAudioEngine`. Both streams are converted to PCM16 24 kHz mono, prefixed with a 1-byte tag (`0x01` mic, `0x02` system), and sent as binary WebSocket frames.

### Frontend (Swift/SwiftUI)

- `ContentView.swift` — Main window with connection badge, panel navigation, recording controls, and elapsed-time display
- `Views/` — TranscriptView, QuestionListView, KnowledgeBaseView, SettingsView, ActivityLogView, ErrorBannerView
- `Views/Setup/` — SetupWizardView, StepProgressBar, EnvironmentStepView, APIKeyStepView, AudioConfigStepView
- `State/AppState.swift` — `@Observable` app state (transcript, questions, KB, settings, activity)
- `State/SetupState.swift` — Setup wizard state machine (steps, sub-steps, statuses, persistence)
- `Services/` — WebSocketClient, EventRouter, AudioDeviceService, SystemAudioCapture (+ MicAudioCapture), SetupManager, PythonManager, KeychainManager
- `Models/Protocol.swift` — Command/event protocol matching the backend

### Backend (Python)

Located in `backend/`. Managed with [uv](https://docs.astral.sh/uv/).

- OpenAI Realtime API transcription with dual audio stream support
- Transcript persistence to `~/.listen/transcripts/`
- LLM-based question detection with rate limiting
- RAG-based answering (hybrid vector + BM25 search, reranking)
- ChromaDB vector store for knowledge base
- Document ingestion (PDF, TXT, MD, DOCX) with chunking and preprocessing
- RAG query logging for analytics
- Text normalization and non-English filtering
- Per-session WebSocket token auth + browser connection rejection
- Single-instance guard via PID file + `fcntl.flock` advisory lock

## Requirements

- macOS 14.2+ (Sonoma or later — required for Core Audio Taps)
- OpenAI API key

> **Note:** Python 3.11+ and [uv](https://docs.astral.sh/uv/) are required but are installed automatically by the setup wizard on first launch.

## Setup

### Download (recommended)

Download the latest release from the [Releases](https://github.com/nimrodhr/Listen2/releases) page. The app is signed and notarized by Apple — just drag it to Applications and launch.

### Build from source

Requires Xcode 16+:

1. Clone the repo and open `LSTN2/LSTN2.xcodeproj` in Xcode
2. Build & run (Cmd+R)

### First launch

On first launch, the **setup wizard** walks through three steps:
   - **Environment** — Installs uv, Python 3.13, and backend dependencies (with per-package transparency info)
   - **API Key** — Enter your OpenAI API key (stored securely in the macOS Keychain)
   - **Audio Config** — Informational screen; system audio is captured natively, no extra drivers needed
The app auto-launches the backend and connects via WebSocket.

The wizard can be re-run from Settings at any time. Setup state is versioned — upgrading LSTN2 may re-trigger the wizard if steps have changed.

### Manual backend setup (optional)

If you prefer to install dependencies yourself:

```bash
cd backend
uv sync
uv run python -m listen.main   # Starts WebSocket server on ws://127.0.0.1:8765
```

## Testing

### Backend (Python)

```bash
cd backend
pytest                                    # All tests
pytest tests/test_transcript_store.py -v  # Verbose single file
```

### Frontend (Swift)

Swift tests are in the `LSTN2Tests` target:

- `EventRouterTests` — English-detection filtering (Latin, Cyrillic, CJK, Arabic, Hebrew, Korean, Japanese)
- `ProtocolTests` — Event envelope parsing, command serialization, protocol version validation

Run via Xcode (Cmd+U) or `xcodebuild test`.

## Features

- **Live Transcription** — Real-time dual-stream transcription (mic + system audio) with speaker labels
- **Question Detection** — Automatically detects questions in conversation, categorized by type (factual, opinion, clarification, action item)
- **RAG Q&A** — Answers questions using knowledge base context with source citations
- **Knowledge Base** — Ingest documents (PDF, TXT, MD, DOCX) into a ChromaDB vector store
- **Transcript Persistence** — Sessions saved to disk for later review
- **Activity Log** — Frontend and backend event tracking with 24-hour retention
- **Setup Wizard** — Guided first-launch experience that installs all prerequisites and configures the app
- **Secure API Key Storage** — OpenAI API key stored in macOS Keychain (migrated from plaintext on upgrade)
- **Native Audio Capture** — System audio via Core Audio Taps and mic via AVAudioEngine — no virtual audio drivers required
- **WebSocket Auth** — Per-session bearer token, browser connection rejection

## Security

- **Apple notarized**: The app is signed with an Apple Developer certificate and notarized by Apple, ensuring it has been scanned for malware and is safe to run.
- **API key storage**: Stored in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Legacy plaintext keys in `settings.json` are migrated automatically and blanked.
- **WebSocket auth**: Backend generates a per-session token (`~/.listen/ws_token`, `0600` permissions) on startup. Frontend sends it as `Authorization: Bearer <token>`. Connections with an `Origin` header (browsers) are rejected.
- **Single instance**: Backend uses PID file + `fcntl.flock` advisory lock + port check. `PythonManager` kills stale processes on port 8765 only after verifying they are Python/uv processes.
- **Settings file**: `~/.listen/settings.json` is written with `0600` permissions.

## Data

All persisted data lives under `~/.listen/`:
- `settings.json` — config (models, audio devices, thresholds) — API key no longer stored here
- `activity.jsonl` — activity log
- `chromadb/` — vector store
- `backend.pid` — single-instance guard
- `backend.lock` — advisory file lock for single-instance enforcement
- `ws_token` — per-session WebSocket auth token (deleted on exit)
- `transcripts/` — saved transcript sessions
- `rag_queries.jsonl` — RAG query analytics
