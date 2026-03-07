# LSTN2

A macOS meeting co-pilot that provides real-time transcription, automatic question detection, and context-aware Q&A — powered by OpenAI and a local knowledge base.

## Features

- **Live Transcription** — Dual-stream capture (microphone + system audio) with real-time speaker-labeled transcription via OpenAI Realtime API
- **Automatic Question Detection** — Identifies questions in conversation, categorized by type (factual, opinion, clarification, action item)
- **RAG-Powered Answers** — Answers detected questions using your knowledge base with source citations (hybrid vector + BM25 search with reranking)
- **Knowledge Base** — Ingest documents (PDF, TXT, MD, DOCX) into a local ChromaDB vector store
- **Transcript Persistence** — Sessions saved to disk with export support
- **Activity Log** — Event tracking with 24-hour retention
- **Menu Bar Access** — Quick toggle via the LSTN2 menu bar icon

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

- macOS 14+
- Xcode 16+
- Python 3.11+ with [uv](https://docs.astral.sh/uv/) (`~/.local/bin/uv`)
- [BlackHole 2ch](https://existential.audio/blackhole/) for system audio capture
- OpenAI API key

## Setup

1. **Clone the repo:**
   ```bash
   git clone https://github.com/nimrodhr/Listen2.git
   cd Listen2
   ```

2. **Install backend dependencies:**
   ```bash
   cd backend
   uv sync
   ```

3. **Configure system audio** — Install [BlackHole 2ch](https://existential.audio/blackhole/) and create a Multi-Output Device in Audio MIDI Setup (combining your speakers/headphones + BlackHole 2ch).

4. **Run the app** — Open `LSTN2/LSTN2.xcodeproj` in Xcode and press Cmd+R. The app auto-launches the Python backend.

5. **Add your API key** — Go to the Settings panel and enter your OpenAI API key.

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
├── LSTN2App.swift             # App entry point, lifecycle
├── ContentView.swift          # Main window with panel navigation
├── State/AppState.swift       # @Observable app state
├── Services/                  # WebSocketClient, EventRouter, PythonManager
├── Views/                     # Transcript, Questions, KB, Settings, Activity
└── Models/Protocol.swift      # WebSocket protocol types

backend/                       # Python backend
├── src/listen/
│   ├── main.py                # Entry point, PID guard
│   ├── config.py              # Pydantic settings schema
│   ├── server/                # WebSocket server, command routing
│   ├── audio/                 # Dual-stream capture, resampling
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
| `rag_queries.jsonl` | RAG query analytics |

## License

This project is for personal use.
