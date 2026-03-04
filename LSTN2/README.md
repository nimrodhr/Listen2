# LSTN2

A macOS meeting co-pilot that provides real-time transcription, question detection, and context-aware Q&A powered by OpenAI and a local knowledge base.

## Architecture

**macOS app (SwiftUI)** communicates over WebSocket with a **Python backend** that handles audio capture, transcription, and intelligence.

```
LSTN2.app  <──WebSocket──>  Python backend (ws://127.0.0.1:8765)
```

### Frontend (Swift/SwiftUI)

- `ContentView.swift` — Main window with header icons for KB, Settings, and Activity panels
- `Views/` — UI components (transcript, questions, settings, knowledge base, activity log)
- `State/AppState.swift` — Observable app state
- `Services/` — WebSocket client, event router, audio device service, Python process manager
- `Models/Protocol.swift` — Command/event protocol matching the backend

### Backend (Python)

Located in `~/Documents/LSTN2/backend/`. Managed with [uv](https://docs.astral.sh/uv/).

- Real-time audio capture (mic + system audio via BlackHole)
- OpenAI-powered transcription (gpt-4o-transcribe)
- Question detection and RAG-based answering
- ChromaDB vector store for knowledge base
- Document ingestion (PDF, TXT, MD, DOCX)

## Requirements

- macOS 14+
- Xcode 16+
- Python 3.11+ with [uv](https://docs.astral.sh/uv/) installed (`~/.local/bin/uv`)
- [BlackHole](https://existential.audio/blackhole/) for system audio capture
- OpenAI API key

## Setup

1. Clone the repo and open `LSTN2.xcodeproj` in Xcode
2. Install the Python backend dependencies:
   ```
   cd ~/Documents/LSTN2/backend
   uv sync
   ```
3. Install BlackHole 2ch and configure a Multi-Output Device in Audio MIDI Setup
4. Run the app from Xcode — it auto-launches the backend and connects via WebSocket
5. Enter your OpenAI API key in Settings

## Features

- **Live Transcription** — Real-time mic and system audio transcription
- **Question Detection** — Automatically detects questions in conversation
- **RAG Q&A** — Answers questions using knowledge base context
- **Knowledge Base** — Ingest documents (PDF, TXT, MD, DOCX) into a ChromaDB vector store
- **Menu Bar** — Quick access via LSTN2 menu bar icon