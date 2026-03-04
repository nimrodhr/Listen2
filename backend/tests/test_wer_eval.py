"""Tests for WER evaluation framework."""

import json
import tempfile
from pathlib import Path

from listen.eval.wer_eval import (
    compute_wer,
    load_transcript_eval_cases,
    run_wer_eval,
    TranscriptEvalCase,
    _normalize_text,
)


class TestNormalizeText:
    def test_lowercase(self):
        assert _normalize_text("Hello World") == ["hello", "world"]

    def test_strip_punctuation(self):
        assert _normalize_text("Hello, world!") == ["hello", "world"]

    def test_preserve_apostrophes(self):
        assert _normalize_text("we're going") == ["we're", "going"]

    def test_collapse_whitespace(self):
        assert _normalize_text("hello   world") == ["hello", "world"]

    def test_empty_string(self):
        assert _normalize_text("") == []

    def test_only_punctuation(self):
        assert _normalize_text("...!!!") == []


class TestComputeWER:
    def test_identical(self):
        result = compute_wer("hello world", "hello world")
        assert result.wer == 0.0
        assert result.substitutions == 0
        assert result.insertions == 0
        assert result.deletions == 0

    def test_one_substitution(self):
        result = compute_wer("hello world", "hello earth")
        assert result.wer == 0.5
        assert result.substitutions == 1
        assert result.insertions == 0
        assert result.deletions == 0

    def test_one_insertion(self):
        result = compute_wer("hello world", "hello big world")
        assert result.wer == 0.5
        assert result.insertions == 1

    def test_one_deletion(self):
        result = compute_wer("hello big world", "hello world")
        assert result.wer == 1 / 3
        assert result.deletions == 1

    def test_empty_reference(self):
        result = compute_wer("", "hello")
        assert result.ref_words == 0
        assert result.insertions == 1

    def test_empty_hypothesis(self):
        result = compute_wer("hello world", "")
        assert result.wer == 1.0
        assert result.deletions == 2

    def test_both_empty(self):
        result = compute_wer("", "")
        assert result.wer == 0.0

    def test_case_insensitive(self):
        result = compute_wer("Hello World", "hello world")
        assert result.wer == 0.0

    def test_punctuation_ignored(self):
        result = compute_wer("Hello, world!", "hello world")
        assert result.wer == 0.0

    def test_complete_mismatch(self):
        result = compute_wer("the cat sat", "a dog stood")
        assert result.wer == 1.0
        assert result.substitutions == 3


class TestLoadEvalCases:
    def test_load_cases(self):
        cases = [
            {"reference": "hello world", "hypothesis": "hello word", "description": "test"},
            {"reference": "good morning", "hypothesis": "good morning"},
        ]
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(cases, f)
            f.flush()
            loaded = load_transcript_eval_cases(f.name)

        assert len(loaded) == 2
        assert loaded[0].reference == "hello world"
        assert loaded[0].hypothesis == "hello word"
        assert loaded[0].description == "test"
        assert loaded[1].description == ""


class TestRunWEREval:
    def test_perfect_score(self):
        cases = [
            TranscriptEvalCase("hello world", "hello world", "perfect"),
            TranscriptEvalCase("good morning", "good morning", "also perfect"),
        ]
        report = run_wer_eval(cases)
        assert report.total_cases == 2
        assert report.avg_wer == 0.0
        assert report.overall_wer == 0.0

    def test_mixed_results(self):
        cases = [
            TranscriptEvalCase("hello world", "hello world", "perfect"),
            TranscriptEvalCase("hello world", "hello earth", "one sub"),
        ]
        report = run_wer_eval(cases)
        assert report.total_cases == 2
        assert report.avg_wer == 0.25  # (0.0 + 0.5) / 2
        assert report.total_substitutions == 1

    def test_empty_cases(self):
        report = run_wer_eval([])
        assert report.total_cases == 0
        assert report.avg_wer == 0.0

    def test_report_has_results(self):
        cases = [TranscriptEvalCase("a b c", "a b d", "test")]
        report = run_wer_eval(cases)
        assert len(report.results) == 1
        assert report.results[0].description == "test"
