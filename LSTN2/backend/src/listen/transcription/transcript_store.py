"""In-memory transcript accumulator with timestamps and speaker labels."""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field, asdict
from typing import Callable, Coroutine, Any, Optional

logger = logging.getLogger("listen.transcription.transcript_store")

TranscriptUpdateCallback = Callable[["TranscriptEntry"], Coroutine[Any, Any, None]]


@dataclass
class TranscriptEntry:
    id: str
    speaker: str  # "me" | "them"
    text: str
    timestamp: float
    is_final: bool
    turn_id: str

    def to_dict(self) -> dict:
        return asdict(self)


class TranscriptStore:
    """Merges transcript deltas from both sessions into a unified,
    chronologically ordered transcript."""

    def __init__(self) -> None:
        self._entries: dict[str, TranscriptEntry] = {}  # keyed by turn_id
        self._ordered_ids: list[str] = []
        self._lock = asyncio.Lock()

        # Callbacks — set by the server to forward events to the frontend
        self.on_delta: Optional[TranscriptUpdateCallback] = None
        self.on_completed: Optional[TranscriptUpdateCallback] = None

    async def add_delta(self, turn_id: str, delta_text: str, speaker: str) -> None:
        """Append a transcript delta. Called when OpenAI sends incremental text."""
        async with self._lock:
            if turn_id in self._entries:
                entry = self._entries[turn_id]
                entry.text += delta_text
            else:
                entry = TranscriptEntry(
                    id=str(uuid.uuid4()),
                    speaker=speaker,
                    text=delta_text,
                    timestamp=time.time(),
                    is_final=False,
                    turn_id=turn_id,
                )
                self._entries[turn_id] = entry
                self._ordered_ids.append(turn_id)

        if self.on_delta:
            await self.on_delta(entry)

    async def finalize_turn(
        self, turn_id: str, final_text: str, speaker: str
    ) -> None:
        """Mark a turn as finalized with the complete text."""
        logger.debug(f"Turn finalized: speaker={speaker}, turn_id={turn_id}, len={len(final_text)}")
        async with self._lock:
            if turn_id in self._entries:
                entry = self._entries[turn_id]
                entry.text = final_text
                entry.is_final = True
            else:
                entry = TranscriptEntry(
                    id=str(uuid.uuid4()),
                    speaker=speaker,
                    text=final_text,
                    timestamp=time.time(),
                    is_final=True,
                    turn_id=turn_id,
                )
                self._entries[turn_id] = entry
                self._ordered_ids.append(turn_id)

        if self.on_completed:
            await self.on_completed(entry)

    def get_recent(self, n: int = 10) -> list[TranscriptEntry]:
        """Get the last N transcript entries in chronological order."""
        recent_ids = self._ordered_ids[-n:]
        return [self._entries[tid] for tid in recent_ids if tid in self._entries]

    def get_recent_by_speaker(
        self, speaker: str, n: int = 10
    ) -> list[TranscriptEntry]:
        """Get the last N finalized entries from a specific speaker."""
        entries = [
            self._entries[tid]
            for tid in self._ordered_ids
            if tid in self._entries
            and self._entries[tid].speaker == speaker
            and self._entries[tid].is_final
        ]
        return entries[-n:]

    def get_recent_seconds(self, seconds: int = 60) -> list[TranscriptEntry]:
        """Get all entries from the last N seconds."""
        cutoff = time.time() - seconds
        return [
            self._entries[tid]
            for tid in self._ordered_ids
            if tid in self._entries and self._entries[tid].timestamp >= cutoff
        ]

    async def clear(self) -> None:
        """Clear all stored transcript entries."""
        count = len(self._entries)
        async with self._lock:
            self._entries.clear()
            self._ordered_ids.clear()
        logger.info(f"Transcript store cleared ({count} entries removed)")

    @property
    def count(self) -> int:
        return len(self._entries)
