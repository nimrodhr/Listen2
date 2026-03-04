"""RAG evaluation framework for measuring retrieval and generation quality.

Usage:
    python -m listen.eval.eval_runner --eval-file eval_questions.json --chromadb-path ~/.listen/chromadb

The eval file should be a JSON array of objects with:
    - question: str — the question to ask
    - expected_answer: str — the gold-standard answer
    - expected_sources: list[str] — file names that should appear in retrieved chunks
    - expected_chunks: list[str] — (optional) substrings that should appear in retrieved text
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger("listen.eval")


@dataclass
class EvalCase:
    question: str
    expected_answer: str
    expected_sources: list[str] = field(default_factory=list)
    expected_chunks: list[str] = field(default_factory=list)


@dataclass
class EvalResult:
    question: str
    # Retrieval metrics
    retrieval_hit: bool = False  # At least one expected source was retrieved
    retrieval_precision: float = 0.0  # Fraction of retrieved chunks from expected sources
    retrieval_recall: float = 0.0  # Fraction of expected sources found in retrieved chunks
    chunk_hit_rate: float = 0.0  # Fraction of expected_chunks found in retrieved text
    # Generation metrics
    has_answer: bool = False
    answer: str = ""
    confidence: float = 0.0
    # Timing
    latency_ms: float = 0.0


@dataclass
class EvalReport:
    total_cases: int = 0
    retrieval_hit_rate: float = 0.0
    avg_retrieval_precision: float = 0.0
    avg_retrieval_recall: float = 0.0
    avg_chunk_hit_rate: float = 0.0
    answer_rate: float = 0.0
    avg_confidence: float = 0.0
    avg_latency_ms: float = 0.0
    results: list[EvalResult] = field(default_factory=list)


def load_eval_cases(path: str) -> list[EvalCase]:
    """Load evaluation cases from a JSON file."""
    data = json.loads(Path(path).read_text())
    cases = []
    for item in data:
        cases.append(EvalCase(
            question=item["question"],
            expected_answer=item.get("expected_answer", ""),
            expected_sources=item.get("expected_sources", []),
            expected_chunks=item.get("expected_chunks", []),
        ))
    return cases


async def run_eval(
    rag_engine,
    cases: list[EvalCase],
    vector_store=None,
    top_k: int = 10,
) -> EvalReport:
    """Run evaluation cases against a RAG engine and compute metrics."""
    results = []

    for case in cases:
        start = time.monotonic()

        # Step 1: Evaluate retrieval (if vector_store provided)
        retrieved_sources = set()
        retrieved_text = ""
        if vector_store:
            matches = vector_store.query(case.question, n_results=top_k)
            for m in matches:
                retrieved_sources.add(m.get("file_name", ""))
                retrieved_text += " " + m.get("text", "")

        # Step 2: Evaluate generation
        rag_result = await rag_engine.answer_question(case.question)

        elapsed_ms = (time.monotonic() - start) * 1000

        # Compute retrieval metrics
        expected_set = set(case.expected_sources)
        if expected_set:
            hits = retrieved_sources & expected_set
            retrieval_hit = len(hits) > 0
            retrieval_recall = len(hits) / len(expected_set)
            retrieval_precision = len(hits) / len(retrieved_sources) if retrieved_sources else 0
        else:
            retrieval_hit = True
            retrieval_recall = 1.0
            retrieval_precision = 1.0

        # Compute chunk hit rate
        if case.expected_chunks:
            found = sum(1 for c in case.expected_chunks if c.lower() in retrieved_text.lower())
            chunk_hit_rate = found / len(case.expected_chunks)
        else:
            chunk_hit_rate = 1.0

        results.append(EvalResult(
            question=case.question,
            retrieval_hit=retrieval_hit,
            retrieval_precision=retrieval_precision,
            retrieval_recall=retrieval_recall,
            chunk_hit_rate=chunk_hit_rate,
            has_answer=rag_result.has_answer,
            answer=rag_result.answer,
            confidence=getattr(rag_result, "confidence", 0.0),
            latency_ms=elapsed_ms,
        ))

    # Aggregate
    n = len(results)
    report = EvalReport(
        total_cases=n,
        retrieval_hit_rate=sum(r.retrieval_hit for r in results) / n if n else 0,
        avg_retrieval_precision=sum(r.retrieval_precision for r in results) / n if n else 0,
        avg_retrieval_recall=sum(r.retrieval_recall for r in results) / n if n else 0,
        avg_chunk_hit_rate=sum(r.chunk_hit_rate for r in results) / n if n else 0,
        answer_rate=sum(r.has_answer for r in results) / n if n else 0,
        avg_confidence=sum(r.confidence for r in results) / n if n else 0,
        avg_latency_ms=sum(r.latency_ms for r in results) / n if n else 0,
        results=results,
    )

    return report


def print_report(report: EvalReport) -> None:
    """Print a human-readable evaluation report."""
    print(f"\n{'='*60}")
    print(f"RAG Evaluation Report ({report.total_cases} cases)")
    print(f"{'='*60}")
    print(f"Retrieval hit rate:      {report.retrieval_hit_rate:.1%}")
    print(f"Avg retrieval precision: {report.avg_retrieval_precision:.1%}")
    print(f"Avg retrieval recall:    {report.avg_retrieval_recall:.1%}")
    print(f"Avg chunk hit rate:      {report.avg_chunk_hit_rate:.1%}")
    print(f"Answer rate:             {report.answer_rate:.1%}")
    print(f"Avg confidence:          {report.avg_confidence:.2f}")
    print(f"Avg latency:             {report.avg_latency_ms:.0f}ms")
    print(f"{'='*60}")

    for i, r in enumerate(report.results):
        status = "PASS" if r.has_answer and r.retrieval_hit else "FAIL"
        print(f"\n[{status}] Q{i+1}: {r.question}")
        print(f"  Retrieval: hit={r.retrieval_hit}, P={r.retrieval_precision:.2f}, R={r.retrieval_recall:.2f}")
        print(f"  Answer: has_answer={r.has_answer}, confidence={r.confidence:.2f}")
        if r.answer:
            print(f"  Response: {r.answer[:120]}...")
    print()
