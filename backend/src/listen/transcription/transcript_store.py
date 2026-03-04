"""In-memory transcript accumulator with timestamps and speaker labels."""

from __future__ import annotations

import asyncio
import logging
import re
import time
import uuid
from dataclasses import dataclass, field, asdict
from typing import Callable, Coroutine, Any, Optional

logger = logging.getLogger("listen.transcription.transcript_store")
logger.info("Transcript store English-only filter ACTIVE (v2)")

# Non-Latin script characters — hard block for English-only mode
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

_SLAVIC_DIACRITICS_RE = re.compile(r"[žšćčđŽŠĆČĐňřťďĺľŕĎŇŘŤĹĽŔ]")


def _is_likely_english(text: str) -> bool:
    """Return True if text appears to be English."""
    stripped = text.strip()
    if not stripped:
        return True  # Allow empty/whitespace (harmless)

    if _NON_LATIN_RE.search(stripped):
        return False

    alpha_chars = sum(1 for c in stripped if c.isalpha())
    if alpha_chars > 0:
        slavic_count = len(_SLAVIC_DIACRITICS_RE.findall(stripped))
        if slavic_count > 0 and slavic_count / alpha_chars > 0.05:
            return False

    return True

TranscriptUpdateCallback = Callable[["TranscriptEntry"], Coroutine[Any, Any, None]]


@dataclass
class TranscriptEntry:
    id: str
    speaker: str  # "me" | "them"
    text: str
    timestamp: float
    is_final: bool
    turn_id: str
    confidence: float = 1.0

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

    async def add_delta(
        self, turn_id: str, delta_text: str, speaker: str, confidence: float = 1.0
    ) -> None:
        """Append a transcript delta. Called when OpenAI sends incremental text."""
        if not _is_likely_english(delta_text):
            logger.info(f"Filtered non-English delta: {delta_text!r}")
            return

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
        self, turn_id: str, final_text: str, speaker: str, confidence: float = 1.0
    ) -> None:
        """Mark a turn as finalized with the complete text."""
        if not _is_likely_english(final_text):
            logger.info(f"Filtered non-English final transcript: {final_text!r}")
            # Remove any partial delta entry that accumulated for this turn
            async with self._lock:
                if turn_id in self._entries:
                    del self._entries[turn_id]
                    self._ordered_ids = [
                        tid for tid in self._ordered_ids if tid != turn_id
                    ]
            return

        logger.debug(
            f"Turn finalized: speaker={speaker}, turn_id={turn_id}, "
            f"len={len(final_text)}, confidence={confidence:.2f}"
        )
        async with self._lock:
            if turn_id in self._entries:
                entry = self._entries[turn_id]
                entry.text = final_text
                entry.is_final = True
                entry.confidence = confidence
            else:
                entry = TranscriptEntry(
                    id=str(uuid.uuid4()),
                    speaker=speaker,
                    text=final_text,
                    timestamp=time.time(),
                    is_final=True,
                    turn_id=turn_id,
                    confidence=confidence,
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
