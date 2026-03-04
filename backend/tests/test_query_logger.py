"""Tests for query logging."""

import json
import tempfile
from pathlib import Path

from listen.intelligence.query_logger import QueryLogger, QueryLogEntry


class TestQueryLogger:
    def test_log_and_read(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "test_queries.jsonl"
            qlogger = QueryLogger(log_path=log_path)

            entry = QueryLogEntry(
                timestamp=1000.0,
                query="What is my latest role?",
                collection="knowledge_base",
                retrieved_count=5,
                answer="Senior Engineer",
                has_answer=True,
                confidence=0.9,
                latency_ms=150.0,
            )
            qlogger.log(entry)

            recent = qlogger.get_recent(10)
            assert len(recent) == 1
            assert recent[0]["query"] == "What is my latest role?"
            assert recent[0]["has_answer"] is True

    def test_stats_computation(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "test_queries.jsonl"
            qlogger = QueryLogger(log_path=log_path)

            for i in range(5):
                entry = QueryLogEntry(
                    timestamp=1000.0 + i,
                    query=f"Question {i}",
                    collection="kb",
                    retrieved_count=3,
                    answer="answer" if i < 3 else "",
                    has_answer=i < 3,
                    confidence=0.8 if i < 3 else 0.0,
                    latency_ms=100.0 + i * 10,
                )
                qlogger.log(entry)

            stats = qlogger.get_stats()
            assert stats["total_queries"] == 5
            assert stats["answered"] == 3
            assert stats["answer_rate"] == 0.6

    def test_truncates_long_chunks(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "test_queries.jsonl"
            qlogger = QueryLogger(log_path=log_path)

            entry = QueryLogEntry(
                timestamp=1000.0,
                query="test",
                collection="kb",
                retrieved_count=1,
                retrieved_chunks=[{"text": "x" * 500, "distance": 0.5}],
            )
            qlogger.log(entry)

            data = json.loads(log_path.read_text().strip())
            assert len(data["retrieved_chunks"][0]["text"]) < 500

    def test_empty_log(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "nonexistent.jsonl"
            qlogger = QueryLogger(log_path=log_path)
            assert qlogger.get_recent() == []
            assert qlogger.get_stats() == {"total_queries": 0}
