"""Single OpenAI Realtime API WebSocket session for transcription."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import time
from typing import Callable, Coroutine, Any, Optional

import websockets

logger = logging.getLogger("listen.transcription.openai_realtime")

REALTIME_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
MAX_SESSION_DURATION = 55 * 60  # Reconnect at 55 minutes (limit is 60)

# Pattern to strip raw VQ audio codec tokens that OpenAI sometimes emits
_VQ_TOKEN_RE = re.compile(r"<\|vq_\w+\|>")

# Callback type: async def callback(turn_id, text, speaker) -> None
TranscriptCallback = Callable[[str, str, str], Coroutine[Any, Any, None]]
ErrorCallback = Callable[[dict], Coroutine[Any, Any, None]]


class OpenAIRealtimeSession:
    """Manages a single WebSocket connection to OpenAI Realtime Transcription API."""

    def __init__(
        self,
        api_key: str,
        label: str,
        model: str = "gpt-4o-transcribe",
        language: str = "en",
        vad_threshold: float = 0.5,
        vad_prefix_padding_ms: int = 300,
        vad_silence_duration_ms: int = 500,
        noise_reduction: str = "near_field",
    ) -> None:
        self.api_key = api_key
        self.label = label  # "me" or "them"
        self.model = model
        self.language = language
        self.vad_threshold = vad_threshold
        self.vad_prefix_padding_ms = vad_prefix_padding_ms
        self.vad_silence_duration_ms = vad_silence_duration_ms
        self.noise_reduction = noise_reduction

        self._ws: Optional[websockets.ClientConnection] = None
        self._audio_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=200)
        self._connected_at: float = 0.0
        self._running = False

        # Callbacks — set by the parent (TranscriptionSessionPair or main.py)
        self.on_transcript_delta: Optional[TranscriptCallback] = None
        self.on_transcript_completed: Optional[TranscriptCallback] = None
        self.on_error: Optional[ErrorCallback] = None

    async def connect(self) -> None:
        """Connect to OpenAI Realtime API and start send/receive loops.
        Automatically reconnects before the 60-minute session limit."""
        self._running = True

        while self._running:
            try:
                headers = {
                    "Authorization": f"Bearer {self.api_key}",
                    "OpenAI-Beta": "realtime=v1",
                }

                logger.info(f"[{self.label}] Connecting to OpenAI Realtime API...")

                self._ws = await websockets.connect(
                    REALTIME_URL,
                    additional_headers=headers,
                    max_size=None,
                )
                self._connected_at = time.time()

                logger.info(f"[{self.label}] Connected to OpenAI Realtime API")
                await self._configure_session()

                # Run send and receive loops; watchdog will cancel them when
                # it's time to reconnect by closing the websocket.
                await asyncio.gather(
                    self._send_loop(),
                    self._receive_loop(),
                    self._reconnect_watchdog(),
                )

            except asyncio.CancelledError:
                self._running = False
                break
            except websockets.ConnectionClosed:
                if not self._running:
                    break
                logger.warning(f"[{self.label}] Connection lost, reconnecting in 2s...")
                await asyncio.sleep(2)
            except Exception as e:
                if not self._running:
                    break
                logger.error(f"[{self.label}] Session error: {e}", exc_info=True)
                await asyncio.sleep(5)

        # Final cleanup
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass

    async def _configure_session(self) -> None:
        """Send session configuration after connecting."""
        config = {
            "type": "transcription_session.update",
            "session": {
                "input_audio_format": "pcm16",
                "input_audio_transcription": {
                    "model": self.model,
                    "language": self.language,
                },
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": self.vad_threshold,
                    "prefix_padding_ms": self.vad_prefix_padding_ms,
                    "silence_duration_ms": self.vad_silence_duration_ms,
                },
                "input_audio_noise_reduction": {
                    "type": self.noise_reduction,
                },
            },
        }
        await self._ws.send(json.dumps(config))
        logger.info(f"[{self.label}] Session configured: model={self.model}")

    async def send_audio(self, pcm_chunk: bytes) -> None:
        """Queue audio data for sending to OpenAI."""
        try:
            self._audio_queue.put_nowait(pcm_chunk)
        except asyncio.QueueFull:
            # Drop oldest chunk to avoid backpressure
            try:
                self._audio_queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
            self._audio_queue.put_nowait(pcm_chunk)

    async def _send_loop(self) -> None:
        """Read from audio queue and send base64-encoded PCM to OpenAI."""
        while self._running:
            try:
                chunk = await asyncio.wait_for(
                    self._audio_queue.get(), timeout=1.0
                )
            except asyncio.TimeoutError:
                continue
            except asyncio.CancelledError:
                break

            audio_b64 = base64.b64encode(chunk).decode("ascii")
            msg = json.dumps({
                "type": "input_audio_buffer.append",
                "audio": audio_b64,
            })
            try:
                await self._ws.send(msg)
            except (websockets.ConnectionClosed, asyncio.CancelledError):
                break

    async def _receive_loop(self) -> None:
        """Receive and dispatch events from OpenAI."""
        try:
            async for message in self._ws:
                event = json.loads(message)
                await self._dispatch_event(event)
        except (websockets.ConnectionClosed, asyncio.CancelledError):
            pass

    async def _dispatch_event(self, event: dict) -> None:
        """Route an incoming OpenAI event to the appropriate callback."""
        event_type = event.get("type", "")

        if event_type == "conversation.item.input_audio_transcription.delta":
            if self.on_transcript_delta:
                delta = _VQ_TOKEN_RE.sub("", event.get("delta", ""))
                if delta:
                    await self.on_transcript_delta(
                        event.get("item_id", ""),
                        delta,
                        self.label,
                    )

        elif event_type == "conversation.item.input_audio_transcription.completed":
            if self.on_transcript_completed:
                transcript = _VQ_TOKEN_RE.sub("", event.get("transcript", ""))
                await self.on_transcript_completed(
                    event.get("item_id", ""),
                    transcript,
                    self.label,
                )

        elif event_type == "transcription_session.created":
            logger.info(f"[{self.label}] Transcription session created")

        elif event_type == "transcription_session.updated":
            logger.info(f"[{self.label}] Transcription session updated")

        elif event_type == "input_audio_buffer.speech_started":
            logger.debug(f"[{self.label}] Speech started")

        elif event_type == "input_audio_buffer.speech_stopped":
            logger.debug(f"[{self.label}] Speech stopped")

        elif event_type == "input_audio_buffer.committed":
            logger.debug(f"[{self.label}] Audio buffer committed")

        elif event_type == "error":
            logger.error(
                f"[{self.label}] OpenAI error: {event.get('error', {}).get('message', 'unknown')}"
            )
            if self.on_error:
                await self.on_error(event)

    async def _reconnect_watchdog(self) -> None:
        """Close the connection before the 60-minute session limit,
        allowing the outer loop to reconnect."""
        while self._running:
            await asyncio.sleep(10)
            elapsed = time.time() - self._connected_at
            if elapsed > MAX_SESSION_DURATION:
                logger.info(
                    f"[{self.label}] Approaching session limit ({elapsed:.0f}s), triggering reconnect..."
                )
                if self._ws:
                    await self._ws.close()
                break

    async def stop(self) -> None:
        """Stop the session and close the connection."""
        self._running = False
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
