"""Manages two concurrent OpenAI Realtime transcription sessions."""

from __future__ import annotations

import asyncio
import logging
from typing import Callable, Optional

from listen.config import TranscriptionConfig
from listen.transcription.openai_realtime import OpenAIRealtimeSession
from listen.transcription.transcript_store import TranscriptStore

logger = logging.getLogger("listen.transcription.session_pair")


class TranscriptionSessionPair:
    """Orchestrates two OpenAI Realtime sessions — one for mic ("me")
    and one for system audio ("them")."""

    def __init__(
        self,
        api_key: str,
        config: TranscriptionConfig,
        model: str = "gpt-4o-transcribe",
        transcript_store: Optional[TranscriptStore] = None,
    ) -> None:
        # Build effective prompt with glossary terms appended
        prompt = config.prompt
        if config.glossary:
            terms = ", ".join(config.glossary)
            prompt += (
                f"\n\nDomain vocabulary (ensure correct transcription): {terms}"
            )
            logger.info(f"Glossary injected into prompt ({len(config.glossary)} terms)")

        self.mic_session = OpenAIRealtimeSession(
            api_key=api_key,
            label="me",
            model=model,
            language=config.language,
            prompt=prompt,
            vad_threshold=config.vad_threshold,
            vad_prefix_padding_ms=config.vad_prefix_padding_ms,
            vad_silence_duration_ms=config.vad_silence_duration_ms,
            noise_reduction=config.noise_reduction,
        )
        self.system_session = OpenAIRealtimeSession(
            api_key=api_key,
            label="them",
            model=model,
            language=config.language,
            prompt=prompt,
            vad_threshold=config.vad_threshold,
            vad_prefix_padding_ms=config.vad_prefix_padding_ms,
            vad_silence_duration_ms=config.vad_silence_duration_ms,
            noise_reduction=config.noise_reduction,
        )

        # Wire up transcript store callbacks
        if transcript_store:
            self.mic_session.on_transcript_delta = transcript_store.add_delta
            self.mic_session.on_transcript_completed = transcript_store.finalize_turn
            self.system_session.on_transcript_delta = transcript_store.add_delta
            self.system_session.on_transcript_completed = (
                transcript_store.finalize_turn
            )

        # Error callback — set by the parent (ws_server)
        self.on_error: Optional[Callable] = None
        self.mic_session.on_error = self._forward_error
        self.system_session.on_error = self._forward_error

        self._tasks: list[asyncio.Task] = []

    async def _forward_error(self, event: dict) -> None:
        """Forward OpenAI errors to the parent callback."""
        if self.on_error:
            await self.on_error(event)

    async def start(self) -> None:
        """Start both transcription sessions concurrently."""
        logger.info("Starting dual transcription sessions...")
        self._tasks = [
            asyncio.create_task(
                self.mic_session.connect(), name="mic_transcription"
            ),
            asyncio.create_task(
                self.system_session.connect(), name="system_transcription"
            ),
        ]

    async def stop(self) -> None:
        """Stop both transcription sessions."""
        logger.info("Stopping dual transcription sessions...")
        # Stop sessions first (sets _running = False and closes ws)
        await self.mic_session.stop()
        await self.system_session.stop()

        # Then cancel tasks to break out of any in-progress reconnect sleep
        for task in self._tasks:
            task.cancel()

        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        self._tasks.clear()

        # Ensure websockets are fully cleaned up
        self.mic_session._ws = None
        self.system_session._ws = None

    async def feed_mic_audio(self, chunk: bytes) -> None:
        """Feed a PCM audio chunk from the microphone."""
        await self.mic_session.send_audio(chunk)

    async def feed_system_audio(self, chunk: bytes) -> None:
        """Feed a PCM audio chunk from system audio (BlackHole)."""
        await self.system_session.send_audio(chunk)
