"""Programmatic text normalization for finalized transcripts."""

from __future__ import annotations

import logging
import re
from typing import Optional

from listen.config import NormalizationConfig

logger = logging.getLogger("listen.transcription.text_normalizer")


class TextNormalizer:
    """Normalizes finalized transcript text: strips fillers, enforces glossary casing,
    and cleans up punctuation artifacts."""

    def __init__(
        self,
        config: NormalizationConfig,
        glossary: Optional[list[str]] = None,
    ) -> None:
        self._config = config
        self._glossary = glossary or []

        # Pre-compile filler patterns (word-boundary matching, case-insensitive)
        self._filler_patterns: list[re.Pattern] = []
        if config.strip_fillers and config.fillers:
            for filler in config.fillers:
                # Match filler as standalone word(s), optionally followed by comma
                pattern = re.compile(
                    r"(?<!\w)" + re.escape(filler) + r",?\s*",
                    re.IGNORECASE,
                )
                self._filler_patterns.append(pattern)

        # Pre-compile glossary case-correction patterns
        self._glossary_patterns: list[tuple[re.Pattern, str]] = []
        for term in self._glossary:
            # Match the term case-insensitively, replace with correct casing
            pattern = re.compile(re.escape(term), re.IGNORECASE)
            self._glossary_patterns.append((pattern, term))

    def normalize(self, text: str) -> str:
        """Apply all normalization steps to the text."""
        if not self._config.enabled or not text.strip():
            return text

        result = text

        # 1. Strip filler words
        if self._config.strip_fillers:
            result = self._strip_fillers(result)

        # 2. Enforce glossary term casing
        if self._glossary_patterns:
            result = self._apply_glossary_casing(result)

        # 3. Clean up artifacts
        result = self._cleanup(result)

        return result

    def _strip_fillers(self, text: str) -> str:
        """Remove filler words while preserving sentence structure."""
        result = text
        for pattern in self._filler_patterns:
            result = pattern.sub("", result)
        return result

    def _apply_glossary_casing(self, text: str) -> str:
        """Enforce correct casing for glossary terms."""
        result = text
        for pattern, replacement in self._glossary_patterns:
            result = pattern.sub(replacement, result)
        return result

    def _cleanup(self, text: str) -> str:
        """Clean up whitespace and punctuation artifacts from filler removal."""
        # Collapse multiple spaces
        result = re.sub(r"  +", " ", text)
        # Remove space before punctuation
        result = re.sub(r"\s+([.,!?;:])", r"\1", result)
        # Remove leading/trailing whitespace
        result = result.strip()
        # Ensure sentence-initial capitalization
        if result and result[0].isalpha():
            result = result[0].upper() + result[1:]
        # Capitalize after sentence-ending punctuation
        result = re.sub(
            r"([.!?]\s+)([a-z])",
            lambda m: m.group(1) + m.group(2).upper(),
            result,
        )
        return result
