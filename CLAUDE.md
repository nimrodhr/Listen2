# LSTN2

Real-time meeting co-pilot: macOS SwiftUI frontend + Python backend connected via WebSocket. Distributed as a DMG; not signed with an Apple Developer ID (users approve via System Settings on first launch).

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
│                     │  text: command.*/event.*  │                      │
│  AppState (@Observable)  binary: tagged audio  │  OpenAI Realtime     │
│  WebSocketClient                               │  Question Detection  │
│  EventRouter                                   │  RAG Engine (KB)     │
│  SystemAudioCapture                            │  Activity Logging    │
│  MicAudioCapture                               │                      │
│  PythonManager                                 │                      │
│  SetupManager / KeychainManager                │                      │
└─────────────────────┘                          └──────────────────────┘
```

**Audio capture**: System audio is captured natively in Swift via `AudioHardwareCreateProcessTap` (Core Audio Taps, macOS 14.2+). Mic audio is captured in Swift via `AVAudioEngine`. Both streams are converted to PCM16 24 kHz mono, prefixed with a 1-byte tag (`0x01` mic, `0x02` system), and sent as binary WebSocket frames.

**Frontend** (Swift, `LSTN2/LSTN2/`): SwiftUI app with `@Observable` AppState. No external dependencies. Includes setup wizard, Keychain-based API key storage, and native dual audio capture.
**Backend** (Python 3.11+, `backend/src/listen/`): Async pipelines for OpenAI Realtime transcription, LLM question detection, and RAG-based answering with ChromaDB. Per-session WS token auth.

### WebSocket Protocol
- Frontend → Backend (text): `command.*` (e.g., `command.start_recording`, `command.query_kb`)
- Frontend → Backend (binary): Tagged PCM16 24kHz mono audio (1-byte prefix: `0x01` mic, `0x02` system)
- Backend → Frontend (text): `event.*` (e.g., `event.transcript.delta`, `event.question.answered`)
- Protocol types defined in both `LSTN2/Models/Protocol.swift` and `backend/src/listen/server/protocol.py` — keep in sync.

## Key Files

### Swift
| File | Purpose |
|------|---------|
| `LSTN2App.swift` | App entry point, lifecycle, backend process management |
| `ContentView.swift` | Main UI container with panel navigation, dual audio streaming |
| `AppState.swift` | Central observable state (transcript, questions, KB, settings); Keychain-first API key loading |
| `SetupState.swift` | Setup wizard state machine (steps, sub-steps, statuses, versioned persistence) |
| `WebSocketClient.swift` | WS connection with exponential backoff reconnect |
| `EventRouter.swift` | Parses events, filters non-English, updates AppState |
| `SystemAudioCapture.swift` | System audio via Core Audio Taps + mic audio via AVAudioEngine (macOS 14.2+) |
| `PythonManager.swift` | Launches/kills backend subprocess, stale process cleanup |
| `SetupManager.swift` | Drives setup wizard: installs uv, Python, deps; saves API key to Keychain |
| `KeychainManager.swift` | Secure API key storage via macOS Keychain (save/load/delete) |

### Python
| File | Purpose |
|------|---------|
| `main.py` | Entry point, signal handling, PID + flock single-instance guard, WS token generation |
| `server/ws_server.py` | WebSocket server, command routing, session coordination, bearer token auth, tagged audio routing |
| `config.py` | Pydantic settings schema, persists to `~/.listen/settings.json` |
| `transcription/openai_realtime.py` | OpenAI Realtime API session (per audio stream) |
| `intelligence/question_detector.py` | LLM-based question extraction from transcript |
| `intelligence/rag_engine.py` | Hybrid search (vector + BM25), rerank, answer generation |
| `knowledge/vector_store.py` | ChromaDB wrapper with multi-collection support |

## Data Locations

All persisted data lives under `~/.listen/`:
- `settings.json` — config (models, audio devices, thresholds) — API key stored in Keychain, not here
- `activity.jsonl` — activity log with 24-hour retention
- `chromadb/` — vector store
- `backend.pid` — single-instance guard
- `backend.lock` — advisory file lock for single-instance enforcement
- `ws_token` — per-session WebSocket auth token (deleted on exit)
- `transcripts/` — saved transcript sessions

## Gotchas

- **Protocol sync**: `Protocol.swift` and `protocol.py` define the same message types — changes must be mirrored in both.
- **WebSocket auth**: Backend generates a per-session token (`~/.listen/ws_token`) on startup. Frontend reads it and sends as `Authorization: Bearer <token>`. Connections from browsers (Origin header) are rejected.
- **Single instance**: Backend uses PID file + `fcntl.flock` advisory lock + port check. Swift's `PythonManager` kills stale processes on port 8765 (only after verifying they are Python/uv processes).
- **English-only filtering**: Both frontend (Swift regex) and backend (Python regex) discard non-Latin script turns entirely. Defense-in-depth.
- **Transcript dedup**: Turns keyed by `turn_id`. Delta events create/update; completion finalizes. Non-English turns are deleted wholesale.
- **Settings not auto-synced**: Frontend settings changes require explicit `update_settings` command to propagate to backend.
- **System audio requires macOS 14.2+**: System audio capture uses `AudioHardwareCreateProcessTap` (Core Audio Taps). User must grant audio capture permission on first use via System Settings > Privacy & Security.
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

- **API key security**: API key is stored in macOS Keychain via `KeychainManager`. Legacy plaintext keys in `settings.json` are migrated on first load and blanked. `settings.json` written with `0600` permissions.
- **Setup wizard versioning**: `SetupState` tracks a setup version (currently `3`). Bumping the version forces re-setup on next launch. Version 2→3 removed the BlackHole audio driver step.

## Testing

```bash
# Backend (Python)
cd backend
pytest                                    # All tests
pytest tests/test_transcript_store.py -v  # Verbose single file

# Frontend (Swift) — run via Xcode (Cmd+U)
# LSTN2Tests target: EventRouterTests, ProtocolTests
```

- pytest config in `pyproject.toml`: `asyncio_mode = "auto"`, `testpaths = ["tests"]`
- Fixtures in `conftest.py` (e.g., `sample_settings_data`)
- Swift tests use the Testing framework (`@Test`): `EventRouterTests` (English detection), `ProtocolTests` (event parsing, command serialization)
