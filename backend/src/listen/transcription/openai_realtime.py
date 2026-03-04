"""Single OpenAI Realtime API WebSocket session for transcription."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import time
from difflib import SequenceMatcher
from typing import Callable, Coroutine, Any, Optional

import websockets

logger = logging.getLogger("listen.transcription.openai_realtime")
logger.info("English-only language filter ACTIVE (v2)")

REALTIME_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
MAX_SESSION_DURATION = 55 * 60  # Reconnect at 55 minutes (limit is 60)

# Pattern to strip raw VQ audio codec tokens that OpenAI sometimes emits
_VQ_TOKEN_RE = re.compile(r"<\|vq_\w+\|>")

# Non-Latin script characters (Cyrillic, Hebrew, Arabic, CJK, Thai, Devanagari, etc.)
_NON_LATIN_RE = re.compile(
    r"[\u0400-\u04FF"   # Cyrillic
    r"\u0500-\u052F"    # Cyrillic Supplement
    r"\u0590-\u05FF"    # Hebrew
    r"\u0600-\u06FF"    # Arabic
    r"\u0900-\u097F"    # Devanagari
    r"\u0E00-\u0E7F"    # Thai
    r"\u3040-\u309F"    # Hiragana
    r"\u30A0-\u30FF"    # Katakana
    r"\u4E00-\u9FFF"    # CJK
    r"\uAC00-\uD7AF"    # Korean
    r"]"
)

# Diacritics common in Slavic languages but very rare in English
_SLAVIC_DIACRITICS_RE = re.compile(r"[žšćčđŽŠĆČĐňřťďĺľŕĎŇŘŤĹĽŔ]")


def _is_likely_english(text: str) -> bool:
    """Return True if text appears to be English, False otherwise."""
    stripped = text.strip()
    if not stripped:
        return False

    # Reject any text containing non-Latin scripts
    if _NON_LATIN_RE.search(stripped):
        return False

    # Reject text with Slavic diacritics (very rare in English)
    alpha_chars = sum(1 for c in stripped if c.isalpha())
    if alpha_chars > 0:
        slavic_count = len(_SLAVIC_DIACRITICS_RE.findall(stripped))
        if slavic_count > 0 and slavic_count / alpha_chars > 0.05:
            return False

    return True


# Callback type: async def callback(turn_id, text, speaker, confidence) -> None
TranscriptCallback = Callable[[str, str, str, float], Coroutine[Any, Any, None]]
ErrorCallback = Callable[[dict], Coroutine[Any, Any, None]]


class OpenAIRealtimeSession:
    """Manages a single WebSocket connection to OpenAI Realtime Transcription API."""

    def __init__(
        self,
        api_key: str,
        label: str,
        model: str = "gpt-4o-transcribe",
        language: str = "en",
        prompt: str = "",
        vad_threshold: float = 0.5,
        vad_prefix_padding_ms: int = 300,
        vad_silence_duration_ms: int = 500,
        noise_reduction: str = "near_field",
    ) -> None:
        self.api_key = api_key
        self.label = label  # "me" or "them"
        self.model = model
        self.language = language
        self.prompt = prompt
        self.vad_threshold = vad_threshold
        self.vad_prefix_padding_ms = vad_prefix_padding_ms
        self.vad_silence_duration_ms = vad_silence_duration_ms
        self.noise_reduction = noise_reduction

        self._ws: Optional[websockets.ClientConnection] = None
        self._audio_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=200)
        self._connected_at: float = 0.0
        self._running = False

        # Confidence estimation state
        self._speech_start_time: Optional[float] = None
        self._speech_stop_time: Optional[float] = None
        self._accumulated_deltas: dict[str, str] = {}  # item_id -> accumulated delta text

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
                    "prompt": self.prompt,
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
            item_id = event.get("item_id", "")
            if self.on_transcript_delta:
                delta = _VQ_TOKEN_RE.sub("", event.get("delta", ""))
                if delta and _is_likely_english(delta):
                    # Accumulate deltas for confidence estimation
                    self._accumulated_deltas[item_id] = (
                        self._accumulated_deltas.get(item_id, "") + delta
                    )
                    await self.on_transcript_delta(
                        item_id,
                        delta,
                        self.label,
                        1.0,  # Deltas always get confidence 1.0 (placeholder)
                    )
                elif delta:
                    logger.info(f"[{self.label}] Filtered non-English delta: {delta!r}")

        elif event_type == "conversation.item.input_audio_transcription.completed":
            item_id = event.get("item_id", "")
            if self.on_transcript_completed:
                transcript = _VQ_TOKEN_RE.sub("", event.get("transcript", ""))
                if _is_likely_english(transcript):
                    confidence = self._estimate_confidence(item_id, transcript)
                    await self.on_transcript_completed(
                        item_id,
                        transcript,
                        self.label,
                        confidence,
                    )
                else:
                    logger.info(f"[{self.label}] Filtered non-English transcript: {transcript!r}")
            # Clean up accumulated deltas for this item
            self._accumulated_deltas.pop(item_id, None)

        elif event_type == "transcription_session.created":
            logger.info(f"[{self.label}] Transcription session created")

        elif event_type == "transcription_session.updated":
            logger.info(f"[{self.label}] Transcription session updated")

        elif event_type == "input_audio_buffer.speech_started":
            self._speech_start_time = time.time()
            logger.debug(f"[{self.label}] Speech started")

        elif event_type == "input_audio_buffer.speech_stopped":
            self._speech_stop_time = time.time()
            logger.debug(f"[{self.label}] Speech stopped")

        elif event_type == "input_audio_buffer.committed":
            logger.debug(f"[{self.label}] Audio buffer committed")

        elif event_type == "error":
            logger.error(
                f"[{self.label}] OpenAI error: {event.get('error', {}).get('message', 'unknown')}"
            )
            if self.on_error:
                await self.on_error(event)

    def _estimate_confidence(self, item_id: str, final_text: str) -> float:
        """Estimate transcription confidence using heuristics.

        Combines two signals:
        - Delta-final similarity: how much the ASR self-corrected (high similarity = high confidence)
        - Speech duration ratio: words-per-second in a plausible range
        """
        # 1. Delta-final divergence
        accumulated = self._accumulated_deltas.get(item_id, "")
        if accumulated and final_text:
            similarity = SequenceMatcher(None, accumulated, final_text).ratio()
        else:
            similarity = 1.0  # No deltas to compare — assume good

        # 2. Speech duration ratio
        duration_score = 1.0
        if self._speech_start_time and self._speech_stop_time:
            duration = self._speech_stop_time - self._speech_start_time
            if duration > 0.1:
                wps = len(final_text.split()) / duration
                # Normal English speech: ~2-4 words/sec; flag outliers
                if wps < 0.3 or wps > 8.0:
                    duration_score = 0.3
                elif wps < 0.8 or wps > 6.0:
                    duration_score = 0.6
                else:
                    duration_score = 1.0

        confidence = 0.6 * similarity + 0.4 * duration_score
        confidence = max(0.0, min(1.0, confidence))

        if confidence < 0.7:
            logger.info(
                f"[{self.label}] Low confidence ({confidence:.2f}) for turn {item_id}: "
                f"similarity={similarity:.2f}, duration_score={duration_score:.2f}"
            )

        return confidence

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
