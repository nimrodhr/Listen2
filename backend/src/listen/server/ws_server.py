"""WebSocket server bridging the Python backend to the Electron frontend."""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path
from typing import Optional

import websockets
from websockets.asyncio.server import Server, ServerConnection

from listen.config import Settings, save_settings
from listen.audio.devices import list_input_devices
from listen.transcription.session_pair import TranscriptionSessionPair
from listen.transcription.transcript_store import TranscriptStore, TranscriptEntry
from listen.transcription.transcript_persistence import TranscriptPersistence
from listen.intelligence.llm_client import create_llm_client
from listen.intelligence.question_detector import QuestionDetector
from listen.intelligence.rag_engine import RAGEngine
from listen.knowledge.vector_store import VectorStore
from listen.knowledge.ingestion import load_directory, scan_directory, load_document
from listen.knowledge.chunking import chunk_documents
from listen.server.protocol import (
    ConnectedEvent,
    PongEvent,
    ErrorEvent,
    RecordingStateEvent,
    SettingsUpdatedEvent,
    AudioDevicesEvent,
    KBStatusEvent,
    KBIngestionProgressEvent,
    KBQueryResultsEvent,
    TranscriptDeltaEvent,
    TranscriptCompletedEvent,
    QuestionDetectedEvent,
    QuestionAnsweredEvent,
    QuestionNoAnswerEvent,
    ActivityLogEntryEvent,
    serialize,
    parse_command,
)
from listen.server.handlers import COMMAND_HANDLERS
from listen.activity import ActivityLog, ActivityLogEntry as ALogEntry

logger = logging.getLogger("listen.server.ws_server")

# User-friendly error messages for known OpenAI error codes
_OPENAI_ERROR_MESSAGES: dict[str, str] = {
    "invalid_api_key": "Your OpenAI API key is invalid. Please update it in Settings.",
    "insufficient_quota": "Your OpenAI account has run out of credits. Add billing at platform.openai.com.",
    "rate_limit_exceeded": "OpenAI rate limit exceeded. Please wait a moment and try again.",
    "model_not_found": "The configured transcription model is not available on your OpenAI account.",
}


class ListenWSServer:
    """WebSocket server that accepts one client (the Electron renderer)."""

    def __init__(self, settings: Settings, ws_token: str = "") -> None:
        self.settings = settings
        self._ws_token = ws_token
        self._server: Optional[Server] = None
        self._client: Optional[ServerConnection] = None
        self._is_recording = False

        # Pipeline components
        self._transcription: Optional[TranscriptionSessionPair] = None
        self._transcript_store = TranscriptStore()
        self._transcript_persistence = TranscriptPersistence()
        self._audio_feed_tasks: list[asyncio.Task] = []
        self._detection_tasks: list[asyncio.Task] = []
        # Audio arrives as tagged binary WebSocket frames from the Swift frontend.
        # Each frame is prefixed with a 1-byte tag: 0x01 = mic, 0x02 = system.
        self._system_audio_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=200)
        self._mic_audio_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=200)

        # Intelligence components
        self._question_detector: Optional[QuestionDetector] = None
        self._rag_engine: Optional[RAGEngine] = None
        self._vector_store: Optional[VectorStore] = None
        self._active_detection_tasks: int = 0
        self._dropped_audio_frames: int = 0
        self._last_drop_log_time: float = 0.0

        # Activity log
        log_path = Path.home() / ".listen" / "activity.jsonl"
        self._activity_log = ActivityLog(log_path)

    async def start(self) -> None:
        """Start the WebSocket server and run forever."""
        host = self.settings.server.ws_host
        port = self.settings.server.ws_port

        # Wire activity log real-time forwarding
        self._activity_log.on_entry = self._on_activity_log_entry

        # Wire transcript store callbacks
        self._transcript_store.on_delta = self._on_transcript_delta
        self._transcript_store.on_completed = self._on_transcript_completed

        # Start the WebSocket server FIRST so the frontend can connect immediately.
        # Vector store initialization can take 30+ seconds and should not block
        # the READY signal — it only needs to be ready before recording starts.
        self._server = await websockets.serve(
            self._handle_client,
            host,
            port,
            # Detect dead clients quickly (e.g. app killed without clean close).
            # Default is 20s/20s which means up to 40s before a zombie is reaped.
            ping_interval=10,
            ping_timeout=5,
        )

        self._activity_log.add("connection", "info", f"Backend started on ws://{host}:{port}")
        logger.info(f"WebSocket server listening on ws://{host}:{port}")
        print(f"READY ws://{host}:{port}", flush=True)

        # Initialize vector store in background (persistent across sessions).
        # This can be slow (embedding model download/init) but recording and
        # transcription work without it — only RAG features need it.
        asyncio.create_task(self._init_vector_store())

        await self._server.wait_closed()

    async def _init_vector_store(self) -> None:
        """Initialize the vector store in the background."""
        try:
            self._vector_store = await asyncio.to_thread(
                VectorStore,
                persist_path=self.settings.knowledge_base.chromadb_path,
                embedding_model=self.settings.models.embedding,
                api_key=self.settings.api_keys.openai,
            )
            self._activity_log.add("knowledge", "info", "Vector store initialized")
        except Exception as e:
            logger.warning(f"Failed to initialize vector store: {e}")
            self._activity_log.add("knowledge", "warning", f"Vector store failed to initialize: {e}")
            # Notify connected client that KB is permanently unavailable
            await self.send_error(
                "KB_INIT_FAILED",
                "Knowledge base failed to initialize. RAG features are unavailable.",
                "kb",
                recoverable=True,
            )

    def _on_activity_log_entry(self, entry: ALogEntry) -> None:
        """Forward a new activity log entry to the connected client."""
        from dataclasses import asdict
        if self._client is not None:
            try:
                loop = asyncio.get_running_loop()
                loop.create_task(
                    self.send(ActivityLogEntryEvent(entry=asdict(entry)))
                )
            except RuntimeError:
                pass  # No running event loop — skip forwarding

    def _init_intelligence(self) -> bool:
        """Initialize question detector and RAG engine based on current settings.

        Returns True on success, False if initialization failed.
        """
        try:
            # Create LLM client for question detection
            qd_model = self.settings.models.question_detection
            llm = create_llm_client(
                model_name=qd_model,
                openai_api_key=self.settings.api_keys.openai,
            )
            self._question_detector = QuestionDetector(
                llm_client=llm,
                transcript_store=self._transcript_store,
                confidence_threshold=self.settings.question_detection.confidence_threshold,
                context_window_turns=self.settings.question_detection.context_window_turns,
            )

            # Create RAG engine
            rag_model = self.settings.models.rag_answer
            rag_llm = create_llm_client(
                model_name=rag_model,
                openai_api_key=self.settings.api_keys.openai,
            )
            if self._vector_store:
                self._rag_engine = RAGEngine(
                    llm_client=rag_llm,
                    vector_store=self._vector_store,
                    top_k=self.settings.rag.top_k,
                )
            self._activity_log.add("intelligence", "info", "Intelligence modules initialized", {
                "question_detection_model": qd_model,
                "rag_model": self.settings.models.rag_answer,
            })
            return True
        except Exception as e:
            logger.warning(f"Failed to initialize intelligence: {e}")
            self._activity_log.add("intelligence", "warning", f"Intelligence init failed: {e}")
            self._question_detector = None
            self._rag_engine = None
            return False

    async def _on_openai_error(self, event: dict) -> None:
        """Forward OpenAI Realtime API errors to the frontend."""
        error_info = event.get("error", {})
        error_msg = error_info.get("message", "Unknown OpenAI error")
        error_code = error_info.get("code", "OPENAI_ERROR")
        logger.error(f"OpenAI Realtime error: {error_msg}")
        self._activity_log.add("transcription", "error", f"OpenAI: {error_msg}", {
            "error_code": error_code,
        })

        # Provide user-friendly messages for known error codes
        user_msg = _OPENAI_ERROR_MESSAGES.get(error_code, error_msg)

        await self.send_error(
            f"OPENAI_{error_code}".upper(),
            user_msg,
            "transcription",
        )

    async def _on_openai_connected(self, label: str) -> None:
        """Log when an OpenAI transcription session connects."""
        source = "Microphone" if label == "me" else "System audio"
        self._activity_log.add("transcription", "info", f"{source} transcription connected to OpenAI")
        logger.info(f"OpenAI transcription session connected: {label}")

    async def _on_transcript_delta(self, entry: TranscriptEntry) -> None:
        """Forward transcript delta to the frontend."""
        await self.send(
            TranscriptDeltaEvent(
                turn_id=entry.turn_id,
                speaker=entry.speaker,
                delta_text=entry.text,
                timestamp=entry.timestamp,
            )
        )

    async def _on_transcript_completed(self, entry: TranscriptEntry) -> None:
        """Forward completed transcript to the frontend, then check for questions."""
        await self.send(
            TranscriptCompletedEvent(
                turn_id=entry.turn_id,
                speaker=entry.speaker,
                final_text=entry.text,
                timestamp=entry.timestamp,
            )
        )

        preview = entry.text[:80] + ("..." if len(entry.text) > 80 else "")
        self._activity_log.add("transcription", "debug", f"Transcript turn completed ({entry.speaker})", {
            "speaker": entry.speaker,
            "turn_id": entry.turn_id,
            "preview": preview,
        })

        # Check for questions from either speaker (limit concurrent detections)
        if self._question_detector and self._active_detection_tasks < 2:
            self._active_detection_tasks += 1
            task = asyncio.create_task(
                self._detect_and_answer(entry.turn_id, entry.text, entry.speaker)
            )
            self._detection_tasks.append(task)
            task.add_done_callback(lambda t: self._detection_tasks.remove(t) if t in self._detection_tasks else None)

    async def _detect_and_answer(self, turn_id: str, text: str, speaker: str = "them") -> None:
        """Run question detection and RAG answer generation."""
        try:
            try:
                question = await self._question_detector.check_for_question(turn_id, text, speaker)
                if not question:
                    return

                self._activity_log.add("intelligence", "info", f"Question detected: {question.question_text[:60]}", {
                    "question_id": question.question_id,
                    "confidence": question.confidence,
                    "category": question.category,
                })

                # Notify frontend of detected question
                await self.send(
                    QuestionDetectedEvent(
                        question_id=question.question_id,
                        question_text=question.question_text,
                        source_turn_id=question.source_turn_id,
                        confidence=question.confidence,
                        category=question.category,
                        timestamp=question.timestamp,
                    )
                )

                # Generate answer via RAG
                if self._rag_engine:
                    result = await self._rag_engine.answer_question(
                        question.question_text
                    )
                    if result.has_answer:
                        self._activity_log.add("intelligence", "info", f"Answer generated for question", {
                            "question_id": question.question_id,
                            "sources_count": len(result.sources),
                        })
                        await self.send(
                            QuestionAnsweredEvent(
                                question_id=question.question_id,
                                answer_text=result.answer,
                                sources=result.sources,
                            )
                        )
                    else:
                        self._activity_log.add("intelligence", "info", "No answer found in knowledge base", {
                            "question_id": question.question_id,
                        })
                        await self.send(
                            QuestionNoAnswerEvent(
                                question_id=question.question_id,
                                reason=result.answer or "No relevant information found in knowledge base.",
                            )
                        )
                else:
                    self._activity_log.add("intelligence", "warning", "Knowledge base not configured")
                    await self.send(
                        QuestionNoAnswerEvent(
                            question_id=question.question_id,
                            reason="Knowledge base not configured.",
                        )
                    )

            except Exception as e:
                logger.error(f"Question detection/answer error: {e}", exc_info=True)
                self._activity_log.add("error", "error", f"Question detection error: {e}")
        finally:
            self._active_detection_tasks -= 1

    async def _health_ping_loop(self) -> None:
        """Send periodic pings to keep the connection alive and let frontend detect staleness."""
        while self._client is not None:
            try:
                await self.send(PongEvent(server_time=time.time()))
                await asyncio.sleep(15)
            except Exception as e:
                logger.warning(f"Health ping failed: {e}")
                break

    async def _handle_client(self, websocket: ServerConnection) -> None:
        """Handle a single client connection."""
        # Reject browser-originated connections (Origin header = CSWSH indicator)
        origin = websocket.request.headers.get("Origin", "")
        if origin:
            logger.warning(f"Rejecting browser connection (Origin: {origin})")
            await websocket.close(1008, "Browser connections not allowed")
            return

        # Validate per-session auth token (generated on backend startup)
        auth_header = websocket.request.headers.get("Authorization", "")
        client_token = auth_header.removeprefix("Bearer ").strip() if auth_header else ""

        if self._ws_token and client_token != self._ws_token:
            logger.warning("Rejecting client: invalid or missing auth token")
            await websocket.close(1008, "Unauthorized")
            return

        # If an old client is still connected (e.g. app was killed without clean
        # disconnect), close it to make room for the new one.  Auth already
        # validated above, so the newcomer is legitimate.
        if self._client is not None:
            logger.warning("Replacing stale client connection with new one")
            self._activity_log.add("connection", "warning", "Closing stale client connection (new client connected)")
            try:
                await self._client.close(1012, "Replaced by new client")
            except Exception:
                pass  # old connection may already be broken

        self._client = websocket
        logger.info("Client connected")
        self._activity_log.add("connection", "info", "Frontend client connected")

        ping_task: asyncio.Task | None = None
        try:
            await self.send(ConnectedEvent())
            # Send persisted settings so the frontend is in sync
            await self.send(
                SettingsUpdatedEvent(settings=self._redacted_settings())
            )
            ping_task = asyncio.create_task(self._health_ping_loop())

            async for message in websocket:
                if isinstance(message, bytes):
                    # Binary frame = tagged audio PCM from Swift frontend.
                    # First byte: 0x01 = mic, 0x02 = system audio.
                    if len(message) < 2:
                        continue
                    tag = message[0]
                    pcm_data = message[1:]
                    target_queue = self._mic_audio_queue if tag == 0x01 else self._system_audio_queue
                    try:
                        target_queue.put_nowait(pcm_data)
                    except asyncio.QueueFull:
                        self._dropped_audio_frames += 1
                        now = time.monotonic()
                        if now - self._last_drop_log_time > 5.0:
                            source = "mic" if tag == 0x01 else "system"
                            logger.warning(f"Dropped {self._dropped_audio_frames} {source} audio frames (queue full)")
                            self._activity_log.add("audio", "warning", f"Dropped {self._dropped_audio_frames} {source} audio frames (queue full)")
                            self._dropped_audio_frames = 0
                            self._last_drop_log_time = now
                else:
                    await self._handle_message(str(message))

        except websockets.ConnectionClosed:
            logger.info("Client disconnected")
            self._activity_log.add("connection", "info", "Frontend client disconnected")
        except Exception as e:
            logger.error(f"Client handler error: {e}", exc_info=True)
            self._activity_log.add("error", "error", f"Client handler error: {e}")
        finally:
            if ping_task is not None:
                ping_task.cancel()
            self._client = None
            self._activity_log.flush()
            logger.info("Client connection cleaned up")

    async def _handle_message(self, raw: str) -> None:
        """Parse and route an incoming command."""
        try:
            msg = parse_command(raw)
            msg_type = msg.get("type", "")

            handler = COMMAND_HANDLERS.get(msg_type)
            if handler:
                await handler(self, msg)
            else:
                logger.warning(f"Unknown command type: {msg_type}")
                await self.send_error(
                    "UNKNOWN_COMMAND",
                    f"Unknown command: {msg_type}",
                    "server",
                )
        except Exception as e:
            logger.error(f"Error handling message: {e}", exc_info=True)
            await self.send_error("HANDLER_ERROR", "An internal error occurred while processing the command.", "server")

    async def send(self, event: object) -> None:
        """Send a protocol event to the connected client."""
        client = self._client
        if client is None:
            return
        try:
            await client.send(serialize(event))
        except websockets.ConnectionClosed:
            # Only clear if it's still the same client (avoid nulling a newer connection)
            if self._client is client:
                self._client = None

    async def send_error(
        self,
        error_code: str,
        message: str,
        component: str,
        recoverable: bool = True,
    ) -> None:
        self._activity_log.add("error", "error", f"[{component}] {message}", {
            "error_code": error_code,
            "component": component,
            "recoverable": recoverable,
        })
        await self.send(
            ErrorEvent(
                error_code=error_code,
                message=message,
                component=component,
                recoverable=recoverable,
            )
        )

    # --- Command implementations ---

    async def start_recording(
        self,
        mic_device_id: Optional[int] = None,
    ) -> None:
        """Start audio capture and transcription pipeline.

        Both mic and system audio arrive as tagged binary WebSocket frames
        from the Swift frontend (mic via AVAudioEngine, system via Core Audio
        Taps). Each frame is prefixed with a 1-byte tag (0x01=mic, 0x02=system).
        """
        if self._is_recording:
            return

        openai_key = self.settings.api_keys.openai
        if not openai_key:
            await self.send_error(
                "OPENAI_KEY_MISSING",
                "OpenAI API key is required for transcription",
                "transcription",
            )
            return

        try:
            await self._transcript_store.clear()
            self._transcript_persistence.start_session()

            # Initialize intelligence modules
            if not self._init_intelligence():
                await self.send_error(
                    "INTELLIGENCE_INIT_FAILED",
                    "Question detection and RAG are unavailable this session.",
                    "intelligence",
                    recoverable=True,
                )

            # Drain any stale audio frames from previous session
            for q in (self._system_audio_queue, self._mic_audio_queue):
                while not q.empty():
                    try:
                        q.get_nowait()
                    except asyncio.QueueEmpty:
                        break

            # Create transcription sessions
            self._transcription = TranscriptionSessionPair(
                api_key=openai_key,
                config=self.settings.transcription,
                model=self.settings.models.transcription,
                transcript_store=self._transcript_store,
                realtime_url=self.settings.models.openai_realtime_url,
            )
            self._transcription.on_error = self._on_openai_error
            self._transcription.on_connected = self._on_openai_connected

            # Start transcription sessions
            await self._transcription.start()

            # Start audio feed tasks — both queues are fed by binary WebSocket
            # frames from the Swift frontend (mic via AVAudioEngine, system via
            # Core Audio Taps).
            self._audio_feed_tasks = [
                asyncio.create_task(
                    self._feed_audio_loop(
                        self._mic_audio_queue,
                        self._transcription.feed_mic_audio,
                    ),
                    name="feed_mic_audio",
                ),
                asyncio.create_task(
                    self._feed_audio_loop(
                        self._system_audio_queue,
                        self._transcription.feed_system_audio,
                    ),
                    name="feed_system_audio",
                ),
            ]

            self._is_recording = True
            await self.send(
                RecordingStateEvent(
                    is_recording=True,
                    mic_active=True,
                    system_audio_active=True,
                )
            )
            logger.info("Recording started")
            self._activity_log.add("recording", "info", "Recording started", {
                "mic_device_id": mic_device_id,
            })

        except Exception as e:
            logger.error(f"Failed to start recording: {e}", exc_info=True)
            self._activity_log.add("error", "error", f"Recording failed to start: {e}")
            await self.stop_recording()
            await self.send_error("RECORDING_START_FAILED", "Failed to start recording. Check API key configuration.", "audio")

    async def _feed_audio_loop(
        self,
        queue: asyncio.Queue[bytes],
        feed_fn,
    ) -> None:
        """Continuously read from an audio queue and feed to a transcription session."""
        consecutive_timeouts = 0
        while self._is_recording:
            try:
                chunk = await asyncio.wait_for(queue.get(), timeout=1.0)
                await feed_fn(chunk)
                consecutive_timeouts = 0
            except asyncio.TimeoutError:
                consecutive_timeouts += 1
                if consecutive_timeouts >= 10:
                    task_name = asyncio.current_task().get_name() if asyncio.current_task() else "unknown"
                    logger.warning(f"Audio feed stalled ({task_name}): {consecutive_timeouts}s with no audio")
                    self._activity_log.add("audio", "warning", f"Audio feed stalled ({task_name})")
                    consecutive_timeouts = 0
                continue
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Audio feed error: {e}", exc_info=True)

    async def stop_recording(self) -> None:
        """Stop audio capture and transcription pipeline."""
        if not self._is_recording:
            return
        self._is_recording = False
        self._dropped_audio_frames = 0

        for task in self._audio_feed_tasks:
            task.cancel()
        if self._audio_feed_tasks:
            await asyncio.gather(*self._audio_feed_tasks, return_exceptions=True)
        self._audio_feed_tasks.clear()

        # Cancel in-flight detection tasks
        for task in self._detection_tasks:
            task.cancel()
        if self._detection_tasks:
            await asyncio.gather(*self._detection_tasks, return_exceptions=True)
        self._detection_tasks.clear()
        self._active_detection_tasks = 0

        try:
            if self._transcription:
                await self._transcription.stop()
                self._transcription = None
        except Exception as e:
            logger.error(f"Error stopping transcription: {e}", exc_info=True)
            self._transcription = None

        try:
            # Save transcript to disk
            await self._transcript_persistence.end_session(self._transcript_store)
        except Exception as e:
            logger.error(f"Error saving transcript: {e}", exc_info=True)

        await self.send(RecordingStateEvent(is_recording=False))
        logger.info("Recording stopped")
        self._activity_log.add("recording", "info", "Recording stopped")

    def _redacted_settings(self) -> dict:
        """Return settings dict with API keys masked."""
        data = self.settings.model_dump()
        if "api_keys" in data:
            for key_name, value in data["api_keys"].items():
                if value and len(value) > 8:
                    data["api_keys"][key_name] = value[:4] + "..." + value[-4:]
                elif value:
                    data["api_keys"][key_name] = "****"
        return data

    async def update_settings(self, settings_data: dict) -> None:
        """Update and persist settings, merging with existing settings."""
        # Merge with existing settings to avoid resetting unset fields
        current = self.settings.model_dump()
        if "settings" in settings_data:
            settings_data = settings_data["settings"]
        for key, value in settings_data.items():
            if isinstance(value, dict) and key in current and isinstance(current[key], dict):
                current[key].update(value)
            else:
                current[key] = value
        self.settings = Settings.model_validate(current)
        save_settings(self.settings)
        try:
            await self.send(
                SettingsUpdatedEvent(settings=self._redacted_settings())
            )
        except Exception as e:
            logger.warning(f"Settings saved but failed to send ack to frontend: {e}")
        self._activity_log.add("settings", "info", "Settings updated")

    async def send_audio_devices(self) -> None:
        """Send available audio devices to the client."""
        input_devs = [
            {
                "id": d.id,
                "name": d.name,
                "channels": d.channels,
                "sample_rate": d.sample_rate,
            }
            for d in list_input_devices()
        ]
        await self.send(
            AudioDevicesEvent(input_devices=input_devs, output_devices=[])
        )
        self._activity_log.add("audio", "debug", f"Audio devices enumerated ({len(input_devs)} input)")

    async def ingest_kb(self, directory: str = "", files: list[str] | None = None) -> None:
        """Ingest knowledge base documents from a directory or individual files."""
        if not self._vector_store:
            await self.send_error("KB_NOT_INITIALIZED", "Vector store not initialized", "kb")
            return

        ALLOWED_EXTENSIONS = {".pdf", ".txt", ".md", ".docx"}

        # Build file list from either directory scan or explicit file paths
        file_paths: list[Path] = []
        if files:
            for f in files:
                p = Path(f).resolve()
                if not p.is_file():
                    logger.warning(f"File not found, skipping: {f}")
                    continue
                if p.suffix.lower() not in ALLOWED_EXTENSIONS:
                    logger.warning(f"Unsupported file type, skipping: {f}")
                    continue
                file_paths.append(p)
        elif directory:
            dir_path = Path(directory)
            if not dir_path.is_dir():
                await self.send_error("KB_DIR_NOT_FOUND", f"Directory not found: {directory}", "kb")
                return
            file_paths = list(scan_directory(directory))
        else:
            await self.send_error("KB_NO_INPUT", "No directory or files provided", "kb")
            return

        total_files = len(file_paths)
        self._activity_log.add("knowledge", "info", f"KB ingestion started ({total_files} files)", {
            "directory": directory,
            "files": [str(f) for f in file_paths] if files else None,
            "total_files": total_files,
        })

        if total_files == 0:
            await self.send_error(
                "KB_NO_FILES",
                "No supported files found (PDF, DOCX, MD, TXT)",
                "kb",
            )
            return

        completed = 0
        for file_path in file_paths:
            try:
                await self.send(
                    KBIngestionProgressEvent(
                        file=file_path.name,
                        status="processing",
                        progress=completed / total_files,
                        total_files=total_files,
                        completed_files=completed,
                    )
                )

                docs = load_document(str(file_path))
                if docs:
                    chunks = chunk_documents(
                        docs,
                        chunk_size=self.settings.knowledge_base.chunk_size,
                        chunk_overlap=self.settings.knowledge_base.chunk_overlap,
                    )
                    self._vector_store.add_documents(chunks)

                completed += 1
                await self.send(
                    KBIngestionProgressEvent(
                        file=file_path.name,
                        status="completed",
                        progress=completed / total_files,
                        total_files=total_files,
                        completed_files=completed,
                    )
                )
            except Exception as e:
                logger.error(f"Failed to ingest {file_path}: {e}", exc_info=True)
                self._activity_log.add("knowledge", "error", f"Failed to ingest {file_path.name}: {e}")
                await self.send(
                    KBIngestionProgressEvent(
                        file=file_path.name,
                        status="failed",
                        progress=completed / total_files,
                        total_files=total_files,
                        completed_files=completed,
                    )
                )

        self._activity_log.add("knowledge", "info", f"KB ingestion completed ({completed}/{total_files} files)")
        # Send final status
        await self.send_kb_status()

    async def remove_kb_source(self, source_path: str) -> None:
        """Remove a source from the knowledge base."""
        if self._vector_store:
            await asyncio.to_thread(self._vector_store.delete_by_source, source_path)
            await self.send_kb_status()

    async def flush_kb(self) -> None:
        """Flush all documents from the knowledge base."""
        if self._vector_store:
            await asyncio.to_thread(self._vector_store.flush)
            self._activity_log.add("knowledge", "info", "Knowledge base flushed")
            await self.send_kb_status()
        else:
            await self.send_error("KB_NOT_INITIALIZED", "Vector store not initialized", "kb")

    async def query_kb(self, query: str, n_results: int = 5) -> None:
        """Query the knowledge base and return matching chunks."""
        if not self._vector_store:
            await self.send_error("KB_NOT_INITIALIZED", "Vector store not initialized", "kb")
            return

        if not query.strip():
            await self.send_error("KB_EMPTY_QUERY", "Query cannot be empty", "kb")
            return

        n_results = max(1, min(n_results, 50))

        try:
            results = await asyncio.to_thread(self._vector_store.query, query, n_results)
            await self.send(
                KBQueryResultsEvent(
                    query=query,
                    results=results,
                    total_results=len(results),
                )
            )
        except Exception as e:
            logger.error(f"KB query failed: {e}", exc_info=True)
            await self.send_error("KB_QUERY_FAILED", "Knowledge base query failed. Please try again.", "kb")

    async def send_kb_status(self) -> None:
        """Send knowledge base status to the client."""
        if self._vector_store:
            stats = await asyncio.to_thread(self._vector_store.get_stats)
            await self.send(
                KBStatusEvent(
                    total_documents=stats["total_documents"],
                    total_chunks=stats["total_chunks"],
                    sources=[
                        {
                            "file_name": s.get("file_name", ""),
                            "source_path": s.get("source", ""),
                            "chunks": s.get("chunks", 0),
                            "last_indexed": "",
                        }
                        for s in stats.get("sources", [])
                    ],
                    index_health=stats.get("index_health", "unknown"),
                    embedding_model=stats.get("embedding_model", ""),
                    vector_db_type=stats.get("vector_db_type", ""),
                    available=True,
                )
            )
        else:
            await self.send(KBStatusEvent(available=False, error="Vector store not initialized"))
