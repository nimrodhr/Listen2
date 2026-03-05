# LSTN2

A macOS meeting co-pilot that provides real-time transcription, question detection, and context-aware Q&A powered by OpenAI and a local knowledge base.

## Architecture

**macOS app (SwiftUI)** communicates over WebSocket with a **Python backend** that handles audio capture, transcription, and intelligence.

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

### Frontend (Swift/SwiftUI)

- `ContentView.swift` — Main window with connection badge, panel navigation, and recording controls
- `Views/` — TranscriptView, QuestionListView, KnowledgeBaseView, SettingsView, ActivityLogView, ErrorBannerView
- `State/AppState.swift` — `@Observable` app state (transcript, questions, KB, settings, activity)
- `Services/` — WebSocketClient, EventRouter, AudioDeviceService, PythonManager
- `Models/Protocol.swift` — Command/event protocol matching the backend

### Backend (Python)

Located in `backend/`. Managed with [uv](https://docs.astral.sh/uv/).

- Dual-stream audio capture (mic + system audio via BlackHole)
- OpenAI Realtime API transcription with session pairs
- Transcript persistence to `~/.listen/transcripts/`
- LLM-based question detection with rate limiting
- RAG-based answering (hybrid vector + BM25 search, reranking)
- ChromaDB vector store for knowledge base
- Document ingestion (PDF, TXT, MD, DOCX) with chunking and preprocessing
- RAG query logging for analytics
- Text normalization and non-English filtering

## Requirements

- macOS 14+
- Xcode 16+
- Python 3.11+ with [uv](https://docs.astral.sh/uv/) installed (`~/.local/bin/uv`)
- [BlackHole 2ch](https://existential.audio/blackhole/) for system audio capture
- OpenAI API key

## Setup

1. Clone the repo and open `LSTN2/LSTN2.xcodeproj` in Xcode
2. Install the Python backend dependencies:
   ```bash
   cd backend
   uv sync
   ```
3. Install BlackHole 2ch and configure a Multi-Output Device in Audio MIDI Setup
4. Run the app from Xcode (Cmd+R) — it auto-launches the backend and connects via WebSocket
5. Enter your OpenAI API key in Settings

## Running the Backend Manually

```bash
cd backend
uv run python -m listen.main   # Starts WebSocket server on ws://127.0.0.1:8765
```

## Testing

```bash
cd backend
pytest                                    # All tests
pytest tests/test_transcript_store.py -v  # Verbose single file
```

## Features

- **Live Transcription** — Real-time dual-stream transcription (mic + system audio) with speaker labels
- **Question Detection** — Automatically detects questions in conversation, categorized by type (factual, opinion, clarification, action item)
- **RAG Q&A** — Answers questions using knowledge base context with source citations
- **Knowledge Base** — Ingest documents (PDF, TXT, MD, DOCX) into a ChromaDB vector store
- **Transcript Persistence** — Sessions saved to disk for later review
- **Activity Log** — Frontend and backend event tracking with 24-hour retention
- **Menu Bar** — Quick access via LSTN2 menu bar icon

## Data

All persisted data lives under `~/.listen/`:
- `settings.json` — config (API keys, models, audio devices, thresholds)
- `activity.jsonl` — activity log
- `chromadb/` — vector store
- `backend.pid` — single-instance guard
- `transcripts/` — saved transcript sessions
- `rag_queries.jsonl` — RAG query analytics
