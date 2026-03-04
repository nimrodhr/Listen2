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

    def get_recent(self, n: int = 50) -> list[dict]:
        """Read the last N log entries."""
        if not self._path.exists():
            return []
        try:
            lines = self._path.read_text().strip().split("\n")
            entries = []
            for line in lines[-n:]:
                if line:
                    entries.append(json.loads(line))
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
