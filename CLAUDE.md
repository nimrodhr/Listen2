# LSTN2

Real-time meeting co-pilot: macOS SwiftUI frontend + Python backend connected via WebSocket.

## Commands

```bash
# Backend
cd backend
uv sync                        # Install/sync dependencies
uv run python -m listen.main   # Run backend (ws://127.0.0.1:8765)
pytest                         # Run all tests
pytest tests/test_transcript_store.py -v  # Single test file

# Frontend
# Open LSTN2/LSTN2.xcodeproj in Xcode, Cmd+R to build & run
# The app auto-launches the backend via PythonManager
```

## Architecture

```
┌─────────────────────┐     WebSocket (8765)     ┌──────────────────────┐
│   SwiftUI Frontend  │ ◄──────────────────────► │   Python Backend     │
│                     │   command.* / event.*     │                      │
│  AppState (@Observable)                        │  Audio → Transcribe  │
│  WebSocketClient                               │  Question Detection  │
│  EventRouter                                   │  RAG Engine (KB)     │
│  PythonManager                                 │  Activity Logging    │
└─────────────────────┘                          └──────────────────────┘
```

**Frontend** (Swift, `LSTN2/LSTN2/`): SwiftUI app with `@Observable` AppState. No external dependencies.
**Backend** (Python 3.11+, `backend/src/listen/`): Async pipelines for audio capture, OpenAI Realtime transcription, LLM question detection, and RAG-based answering with ChromaDB.

### WebSocket Protocol
- Frontend → Backend: `command.*` (e.g., `command.start_recording`, `command.query_kb`)
- Backend → Frontend: `event.*` (e.g., `event.transcript.delta`, `event.question.answered`)
- Protocol types defined in both `LSTN2/Models/Protocol.swift` and `backend/src/listen/server/protocol.py` — keep in sync.

## Key Files

### Swift
| File | Purpose |
|------|---------|
| `LSTN2App.swift` | App entry point, lifecycle, backend process management |
| `ContentView.swift` | Main UI container with panel navigation |
| `AppState.swift` | Central observable state (transcript, questions, KB, settings) |
| `WebSocketClient.swift` | WS connection with exponential backoff reconnect |
| `EventRouter.swift` | Parses events, filters non-English, updates AppState |
| `PythonManager.swift` | Launches/kills backend subprocess, stale process cleanup |

### Python
| File | Purpose |
|------|---------|
| `main.py` | Entry point, signal handling, single-instance PID guard |
| `server/ws_server.py` | WebSocket server, command routing, session coordination |
| `config.py` | Pydantic settings schema, persists to `~/.listen/settings.json` |
| `transcription/openai_realtime.py` | OpenAI Realtime API session (per audio stream) |
| `intelligence/question_detector.py` | LLM-based question extraction from transcript |
| `intelligence/rag_engine.py` | Hybrid search (vector + BM25), rerank, answer generation |
| `knowledge/vector_store.py` | ChromaDB wrapper with multi-collection support |

## Data Locations

All persisted data lives under `~/.listen/`:
- `settings.json` — shared config (API keys, models, audio devices, thresholds)
- `activity.jsonl` — activity log with 24-hour retention
- `chromadb/` — vector store
- `backend.pid` — single-instance guard
- `transcripts/` — saved transcript sessions

## Gotchas

- **Protocol sync**: `Protocol.swift` and `protocol.py` define the same message types — changes must be mirrored in both.
- **Single instance**: Backend uses PID file + port check. Swift's `PythonManager` force-kills stale processes on port 8765.
- **English-only filtering**: Both frontend (Swift regex) and backend (Python regex) discard non-Latin script turns entirely. Defense-in-depth.
- **Transcript dedup**: Turns keyed by `turn_id`. Delta events create/update; completion finalizes. Non-English turns are deleted wholesale.
- **Settings not auto-synced**: Frontend settings changes require explicit `update_settings` command to propagate to backend.
- **BlackHole required**: System audio capture needs BlackHole 2ch virtual audio loopback installed + Multi-Output Device configured in Audio MIDI Setup.
- **Question detection rate limit**: Max 1 detection per 3 seconds per speaker to avoid hammering the LLM.
- **Frontend transcript cap**: UI keeps max 200 entries; full session persisted to disk.
- **RAG similarity threshold**: Default 1.5 (ChromaDB distance). Lower = stricter filtering.
- **uv path**: `PythonManager` expects `uv` at `~/.local/bin/uv`.

## Code Style

### Swift
- `@Observable` + `@MainActor` for state, async/await for concurrency
- `os.log` with subsystem/category for logging
- Guard-based early returns, optional chaining

### Python
- `asyncio` throughout, async callbacks for event forwarding
- Pydantic `BaseModel` for config, `@dataclass` for protocol messages
- Custom exception hierarchy (`ListenError` → `AudioError`, `TranscriptionError`, etc.)
- `asyncio.Lock` for thread-safe transcript accumulation

## Testing

```bash
cd backend
pytest                                    # All tests
pytest tests/test_transcript_store.py -v  # Verbose single file
```

- pytest config in `pyproject.toml`: `asyncio_mode = "auto"`, `testpaths = ["tests"]`
- Fixtures in `conftest.py` (e.g., `sample_settings_data`)
- No Swift tests currently
