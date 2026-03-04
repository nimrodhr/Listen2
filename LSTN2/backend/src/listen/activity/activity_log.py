"""Persistent activity log with JSONL storage and 24-hour retention."""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Callable, Optional

logger = logging.getLogger("listen.activity.activity_log")

RETENTION_HOURS = 24


@dataclass
class ActivityLogEntry:
    id: str
    timestamp: float
    category: str  # recording | transcription | intelligence | knowledge | connection | settings | audio | error
    level: str  # info | warning | error | debug
    title: str
    details: Optional[dict] = None


class ActivityLog:
    """Append-only activity log persisted to a JSONL file."""

    def __init__(self, log_path: Path) -> None:
        self._log_path = log_path
        self._entries: list[ActivityLogEntry] = []
        self._pending_writes: list[ActivityLogEntry] = []
        self._last_flush: float = 0.0
        self._on_entry: Optional[Callable[[ActivityLogEntry], None]] = None
        self._load()

    @property
    def on_entry(self) -> Optional[Callable[[ActivityLogEntry], None]]:
        return self._on_entry

    @on_entry.setter
    def on_entry(self, callback: Optional[Callable[[ActivityLogEntry], None]]) -> None:
        self._on_entry = callback

    def add(
        self,
        category: str,
        level: str,
        title: str,
        details: Optional[dict] = None,
    ) -> ActivityLogEntry:
        """Create and persist a new log entry."""
        entry = ActivityLogEntry(
            id=uuid.uuid4().hex[:12],
            timestamp=time.time(),
            category=category,
            level=level,
            title=title,
            details=details,
        )
        self._entries.append(entry)
        self._pending_writes.append(entry)

        # Batch flush every 2 seconds to avoid blocking event loop on every call
        now = time.time()
        if now - self._last_flush >= 2.0:
            self._flush_pending()

        if self._on_entry:
            self._on_entry(entry)

        return entry

    def _flush_pending(self) -> None:
        """Flush pending writes to disk."""
        if not self._pending_writes:
            return
        try:
            self._log_path.parent.mkdir(parents=True, exist_ok=True)
            is_new = not self._log_path.exists()
            with open(self._log_path, "a") as f:
                for entry in self._pending_writes:
                    f.write(json.dumps(asdict(entry)) + "\n")
            if is_new:
                os.chmod(self._log_path, 0o600)
            self._pending_writes.clear()
            self._last_flush = time.time()
        except OSError as e:
            logger.warning(f"Failed to flush activity log: {e}")

    def get_recent(self, hours: float = RETENTION_HOURS) -> list[ActivityLogEntry]:
        """Return entries from the last N hours, oldest first."""
        cutoff = time.time() - hours * 3600
        return [e for e in self._entries if e.timestamp >= cutoff]

    def _load(self) -> None:
        """Load entries from disk, keeping only the last 24 hours."""
        if not self._log_path.exists():
            return

        cutoff = time.time() - RETENTION_HOURS * 3600
        kept: list[ActivityLogEntry] = []

        try:
            with open(self._log_path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        data = json.loads(line)
                        entry = ActivityLogEntry(**data)
                        if entry.timestamp >= cutoff:
                            kept.append(entry)
                    except (json.JSONDecodeError, TypeError):
                        continue
        except OSError as e:
            logger.warning(f"Failed to load activity log: {e}")

        self._entries = kept

        # Prune the file to only keep recent entries
        if kept:
            self._rewrite(kept)

    def _append(self, entry: ActivityLogEntry) -> None:
        """Append a single entry to the JSONL file."""
        try:
            self._log_path.parent.mkdir(parents=True, exist_ok=True)
            with open(self._log_path, "a") as f:
                f.write(json.dumps(asdict(entry)) + "\n")
        except OSError as e:
            logger.warning(f"Failed to write activity log entry: {e}")

    def flush(self) -> None:
        """Force-flush all pending writes to disk. Call on shutdown."""
        self._flush_pending()

    def _rewrite(self, entries: list[ActivityLogEntry]) -> None:
        """Rewrite the JSONL file with only the given entries."""
        try:
            self._log_path.parent.mkdir(parents=True, exist_ok=True)
            with open(self._log_path, "w") as f:
                for entry in entries:
                    f.write(json.dumps(asdict(entry)) + "\n")
            os.chmod(self._log_path, 0o600)
        except OSError as e:
            logger.warning(f"Failed to rewrite activity log: {e}")
