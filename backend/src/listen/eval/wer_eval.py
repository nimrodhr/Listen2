"""Word Error Rate (WER) evaluation framework for transcription quality.

Usage:
    python -m listen.eval.wer_eval --eval-file eval_transcripts.json

The eval file should be a JSON array of objects with:
    - reference: str — the gold-standard transcript
    - hypothesis: str — the ASR output to evaluate
    - description: str — (optional) description of the test case
"""

from __future__ import annotations

import argparse
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("listen.eval.wer")


@dataclass
class WERResult:
    """Result of a single WER computation."""
    wer: float
    substitutions: int
    insertions: int
    deletions: int
    ref_words: int
    hyp_words: int


@dataclass
class TranscriptEvalCase:
    """A single evaluation case."""
    reference: str
    hypothesis: str
    description: str = ""


@dataclass
class CaseResult:
    """Result for a single evaluation case."""
    description: str
    reference: str
    hypothesis: str
    wer_result: WERResult


@dataclass
class WEREvalReport:
    """Aggregate WER evaluation report."""
    total_cases: int = 0
    avg_wer: float = 0.0
    min_wer: float = 0.0
    max_wer: float = 0.0
    total_ref_words: int = 0
    total_substitutions: int = 0
    total_insertions: int = 0
    total_deletions: int = 0
    overall_wer: float = 0.0  # Corpus-level WER (total errors / total ref words)
    results: list[CaseResult] = field(default_factory=list)


def _normalize_text(text: str) -> list[str]:
    """Normalize text for WER comparison: lowercase, strip punctuation, split."""
    import re
    text = text.lower().strip()
    # Remove punctuation except apostrophes within words
    text = re.sub(r"[^\w\s']", " ", text)
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text.split()


def compute_wer(reference: str, hypothesis: str) -> WERResult:
    """Compute Word Error Rate using Levenshtein edit distance on words.

    WER = (S + D + I) / N where:
    - S = substitutions, D = deletions, I = insertions
    - N = number of words in reference
    """
    ref_words = _normalize_text(reference)
    hyp_words = _normalize_text(hypothesis)
    n = len(ref_words)
    m = len(hyp_words)

    if n == 0:
        return WERResult(
            wer=0.0 if m == 0 else float(m),
            substitutions=0,
            insertions=m,
            deletions=0,
            ref_words=0,
            hyp_words=m,
        )

    # Dynamic programming matrix for edit distance
    # dp[i][j] = (distance, substitutions, insertions, deletions)
    dp = [[(0, 0, 0, 0) for _ in range(m + 1)] for _ in range(n + 1)]

    for i in range(1, n + 1):
        dp[i][0] = (i, 0, 0, i)  # All deletions
    for j in range(1, m + 1):
        dp[0][j] = (j, 0, j, 0)  # All insertions

    for i in range(1, n + 1):
        for j in range(1, m + 1):
            if ref_words[i - 1] == hyp_words[j - 1]:
                dp[i][j] = dp[i - 1][j - 1]
            else:
                # Substitution
                sub = dp[i - 1][j - 1]
                sub_cost = (sub[0] + 1, sub[1] + 1, sub[2], sub[3])
                # Insertion (extra word in hypothesis)
                ins = dp[i][j - 1]
                ins_cost = (ins[0] + 1, ins[1], ins[2] + 1, ins[3])
                # Deletion (missing word in hypothesis)
                dele = dp[i - 1][j]
                del_cost = (dele[0] + 1, dele[1], dele[2], dele[3] + 1)

                dp[i][j] = min(sub_cost, ins_cost, del_cost, key=lambda x: x[0])

    dist, subs, ins, dels = dp[n][m]
    wer = dist / n

    return WERResult(
        wer=wer,
        substitutions=subs,
        insertions=ins,
        deletions=dels,
        ref_words=n,
        hyp_words=m,
    )


def load_transcript_eval_cases(path: str) -> list[TranscriptEvalCase]:
    """Load evaluation cases from a JSON file."""
    data = json.loads(Path(path).read_text())
    cases = []
    for item in data:
        cases.append(TranscriptEvalCase(
            reference=item["reference"],
            hypothesis=item["hypothesis"],
            description=item.get("description", ""),
        ))
    return cases


def run_wer_eval(cases: list[TranscriptEvalCase]) -> WEREvalReport:
    """Run WER evaluation on a list of cases."""
    results = []
    for case in cases:
        wer_result = compute_wer(case.reference, case.hypothesis)
        results.append(CaseResult(
            description=case.description,
            reference=case.reference,
            hypothesis=case.hypothesis,
            wer_result=wer_result,
        ))

    n = len(results)
    if n == 0:
        return WEREvalReport()

    wers = [r.wer_result.wer for r in results]
    total_ref = sum(r.wer_result.ref_words for r in results)
    total_subs = sum(r.wer_result.substitutions for r in results)
    total_ins = sum(r.wer_result.insertions for r in results)
    total_dels = sum(r.wer_result.deletions for r in results)

    return WEREvalReport(
        total_cases=n,
        avg_wer=sum(wers) / n,
        min_wer=min(wers),
        max_wer=max(wers),
        total_ref_words=total_ref,
        total_substitutions=total_subs,
        total_insertions=total_ins,
        total_deletions=total_dels,
        overall_wer=(total_subs + total_ins + total_dels) / total_ref if total_ref > 0 else 0.0,
        results=results,
    )


def print_wer_report(report: WEREvalReport) -> None:
    """Print a human-readable WER evaluation report."""
    print(f"\n{'=' * 60}")
    print(f"WER Evaluation Report ({report.total_cases} cases)")
    print(f"{'=' * 60}")
    print(f"Overall WER (corpus):    {report.overall_wer:.1%}")
    print(f"Average WER (per-case):  {report.avg_wer:.1%}")
    print(f"Min WER:                 {report.min_wer:.1%}")
    print(f"Max WER:                 {report.max_wer:.1%}")
    print(f"Total reference words:   {report.total_ref_words}")
    print(f"Total substitutions:     {report.total_substitutions}")
    print(f"Total insertions:        {report.total_insertions}")
    print(f"Total deletions:         {report.total_deletions}")
    print(f"{'=' * 60}")

    for i, r in enumerate(report.results):
        status = "GOOD" if r.wer_result.wer < 0.1 else "OK" if r.wer_result.wer < 0.2 else "POOR"
        print(f"\n[{status}] Case {i + 1}: {r.description or '(no description)'}")
        print(f"  WER: {r.wer_result.wer:.1%} "
              f"(S={r.wer_result.substitutions}, I={r.wer_result.insertions}, D={r.wer_result.deletions})")
        print(f"  Ref:  {r.reference[:100]}{'...' if len(r.reference) > 100 else ''}")
        print(f"  Hyp:  {r.hypothesis[:100]}{'...' if len(r.hypothesis) > 100 else ''}")
    print()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run WER evaluation on transcript pairs")
    parser.add_argument("--eval-file", required=True, help="Path to JSON eval file")
    args = parser.parse_args()

    cases = load_transcript_eval_cases(args.eval_file)
    report = run_wer_eval(cases)
    print_wer_report(report)
