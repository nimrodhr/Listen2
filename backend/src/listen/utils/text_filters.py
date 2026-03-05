"""Shared text filtering utilities for English-only transcription."""

from __future__ import annotations

import re

# Non-Latin script characters (Cyrillic, Hebrew, Arabic, CJK, Thai, Devanagari, etc.)
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

# Diacritics common in Slavic languages but very rare in English
_SLAVIC_DIACRITICS_RE = re.compile(r"[žšćčđŽŠĆČĐňřťďĺľŕĎŇŘŤĹĽŔ]")


def is_likely_english(text: str) -> bool:
    """Return True if text appears to be English, False otherwise.

    Empty/whitespace-only text returns False (treated as non-content).
    """
    stripped = text.strip()
    if not stripped:
        return False

    # Reject any text containing non-Latin scripts
    if _NON_LATIN_RE.search(stripped):
        return False

    # Reject text with Slavic diacritics (very rare in English)
    alpha_chars = sum(1 for c in stripped if c.isalpha())
    if alpha_chars > 0:
        slavic_count = len(_SLAVIC_DIACRITICS_RE.findall(stripped))
        if slavic_count > 0 and slavic_count / alpha_chars > 0.05:
            return False

    return True
