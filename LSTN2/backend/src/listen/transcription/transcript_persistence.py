"""Save and load transcripts to/from disk."""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from listen.transcription.transcript_store import TranscriptStore

logger = logging.getLogger("listen.transcription.transcript_persistence")

TRANSCRIPTS_DIR = Path.home() / ".listen" / "transcripts"


class TranscriptPersistence:
    """Saves finalized transcript sessions to disk as JSON files."""

    def __init__(self, transcripts_dir: Optional[str] = None) -> None:
        self._dir = Path(transcripts_dir) if transcripts_dir else TRANSCRIPTS_DIR
        self._dir.mkdir(parents=True, exist_ok=True)
        self._current_session_id: Optional[str] = None
        self._session_start: Optional[float] = None

    def start_session(self) -> str:
        """Begin a new transcript session. Returns the session ID."""
        now = datetime.now()
        self._current_session_id = now.strftime("%Y%m%d_%H%M%S")
        self._session_start = time.time()
        logger.info(f"Transcript session started: {self._current_session_id}")
        return self._current_session_id

    def save_session(self, store: TranscriptStore) -> Optional[Path]:
        """Save the current transcript store contents to a JSON file."""
        if not self._current_session_id:
            logger.warning("No active session to save")
            return None

        entries = store.get_recent(n=10000)  # Get all entries
        if not entries:
            logger.info("No transcript entries to save")
            return None

        file_path = self._dir / f"transcript_{self._current_session_id}.json"

        data = {
            "session_id": self._current_session_id,
            "started_at": self._session_start,
            "saved_at": time.time(),
            "entry_count": len(entries),
            "entries": [
                {
                    "turn_id": e.turn_id,
                    "speaker": e.speaker,
                    "text": e.text,
                    "timestamp": e.timestamp,
                    "is_final": e.is_final,
                }
                for e in entries
                if e.is_final  # Only save finalized entries
            ],
        }

        file_path.write_text(json.dumps(data, indent=2))
        os.chmod(file_path, 0o600)
        logger.info(
            f"Transcript saved: {file_path} ({len(data['entries'])} entries)"
        )
        return file_path

    def end_session(self, store: TranscriptStore) -> Optional[Path]:
        """End the current session and save transcript."""
        path = self.save_session(store)
        self._current_session_id = None
        self._session_start = None
        return path

    def list_sessions(self) -> list[dict]:
        """List all saved transcript sessions."""
        sessions = []
        for file_path in sorted(self._dir.glob("transcript_*.json"), reverse=True):
            try:
                data = json.loads(file_path.read_text())
                sessions.append({
                    "session_id": data.get("session_id", ""),
                    "started_at": data.get("started_at", 0),
                    "saved_at": data.get("saved_at", 0),
                    "entry_count": data.get("entry_count", 0),
                    "file_path": str(file_path),
                })
            except Exception as e:
                logger.warning(f"Failed to read transcript {file_path}: {e}")
        return sessions

    def _safe_session_path(self, session_id: str) -> Optional[Path]:
        """Resolve a session file path, rejecting path traversal attempts."""
        # Strip any path separators to prevent traversal
        safe_id = session_id.replace("/", "").replace("\\", "").replace("..", "")
        if not safe_id:
            return None
        file_path = (self._dir / f"transcript_{safe_id}.json").resolve()
        # Ensure the resolved path is still within the transcripts directory
        if not str(file_path).startswith(str(self._dir.resolve())):
            logger.warning(f"Path traversal attempt blocked: {session_id}")
            return None
        return file_path

    def load_session(self, session_id: str) -> Optional[dict]:
        """Load a saved transcript session by ID."""
        file_path = self._safe_session_path(session_id)
        if not file_path or not file_path.exists():
            return None
        try:
            return json.loads(file_path.read_text())
        except Exception as e:
            logger.error(f"Failed to load transcript {session_id}: {e}")
            return None

    def delete_session(self, session_id: str) -> bool:
        """Delete a saved transcript session."""
        file_path = self._safe_session_path(session_id)
        if not file_path:
            return False
        if file_path.exists():
            file_path.unlink()
            logger.info(f"Transcript deleted: {session_id}")
            return True
        return False
