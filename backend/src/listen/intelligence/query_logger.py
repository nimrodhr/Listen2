"""Production query logging for RAG pipeline analytics."""

from __future__ import annotations

import json
import logging
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger("listen.intelligence.query_logger")

DEFAULT_LOG_PATH = Path.home() / ".listen" / "rag_queries.jsonl"


@dataclass
class QueryLogEntry:
    timestamp: float
    query: str
    collection: str
    retrieved_count: int
    retrieved_chunks: list[dict] = field(default_factory=list)
    reranked_count: int = 0
    reranked_chunks: list[dict] = field(default_factory=list)
    answer: str = ""
    has_answer: bool = False
    confidence: float = 0.0
    latency_ms: float = 0.0
    similarity_threshold: float = 0.0
    chunks_filtered_by_threshold: int = 0
    cache_hit: bool = False


class QueryLogger:
    """Append-only JSONL logger for RAG queries and results."""

    def __init__(self, log_path: Optional[Path] = None) -> None:
        self._path = log_path or DEFAULT_LOG_PATH
        self._path.parent.mkdir(parents=True, exist_ok=True)

    def log(self, entry: QueryLogEntry) -> None:
        """Append a query log entry to the JSONL file."""
        try:
            # Rotate if file exceeds max size
            if self._path.exists() and self._path.stat().st_size > self.MAX_LOG_SIZE:
                rotated = self._path.with_suffix(".jsonl.old")
                try:
                    import os
                    os.replace(self._path, rotated)
                except OSError:
                    pass
            record = asdict(entry)
            # Truncate chunk texts to save disk space
            for chunk_list_key in ("retrieved_chunks", "reranked_chunks"):
                for chunk in record.get(chunk_list_key, []):
                    if "text" in chunk and len(chunk["text"]) > 200:
                        chunk["text"] = chunk["text"][:200] + "..."
            with open(self._path, "a") as f:
                f.write(json.dumps(record) + "\n")
        except Exception as e:
            logger.warning(f"Failed to write query log: {e}")

    MAX_LOG_SIZE = 10 * 1024 * 1024  # 10 MB

    def get_recent(self, n: int = 50) -> list[dict]:
        """Read the last N log entries efficiently from the end of the file."""
        if not self._path.exists():
            return []
        try:
            # Read only the tail of the file to avoid loading megabytes
            with open(self._path, "rb") as f:
                f.seek(0, 2)  # Seek to end
                size = f.tell()
                # Read last ~64KB which should contain well over 50 entries
                read_size = min(size, 64 * 1024)
                f.seek(max(0, size - read_size))
                tail = f.read().decode("utf-8", errors="replace")

            lines = tail.strip().split("\n")
            entries = []
            for line in lines[-n:]:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
            return entries
        except Exception as e:
            logger.warning(f"Failed to read query log: {e}")
            return []

    def get_stats(self) -> dict:
        """Compute summary statistics from the query log."""
        entries = self.get_recent(1000)
        if not entries:
            return {"total_queries": 0}

        total = len(entries)
        answered = sum(1 for e in entries if e.get("has_answer"))
        avg_latency = sum(e.get("latency_ms", 0) for e in entries) / total
        avg_confidence = sum(e.get("confidence", 0) for e in entries if e.get("has_answer")) / max(answered, 1)
        cache_hits = sum(1 for e in entries if e.get("cache_hit"))

        return {
            "total_queries": total,
            "answered": answered,
            "answer_rate": round(answered / total, 3) if total else 0,
            "avg_latency_ms": round(avg_latency, 1),
            "avg_confidence": round(avg_confidence, 3),
            "cache_hit_rate": round(cache_hits / total, 3) if total else 0,
        }
