"""LLM-based post-transcription correction for low-confidence turns."""

from __future__ import annotations

import logging
from typing import Optional

from listen.intelligence.llm_client import LLMClient

logger = logging.getLogger("listen.transcription.transcript_corrector")

CORRECTION_PROMPT = """Fix any speech recognition errors in the following transcript segment.
Use the provided glossary and conversation context to identify likely corrections.
Only fix clear errors — do not change meaning, style, or add content.
If the transcript looks correct, return it unchanged.

{glossary_section}
Recent conversation context:
{context}

Transcript to correct:
"{text}"

Return ONLY the corrected transcript text, nothing else."""


class TranscriptCorrector:
    """Corrects transcription errors using an LLM with glossary and context."""

    def __init__(
        self,
        llm_client: LLMClient,
        glossary: Optional[list[str]] = None,
    ) -> None:
        self._llm = llm_client
        self._glossary = glossary or []

    async def correct(
        self,
        text: str,
        context: str,
        confidence: float,
    ) -> Optional[str]:
        """Correct a transcript segment using LLM.

        Returns the corrected text, or None if no correction was made.
        """
        if not text.strip():
            return None

        glossary_section = ""
        if self._glossary:
            terms = ", ".join(self._glossary)
            glossary_section = f"Domain glossary: {terms}\n"

        prompt = CORRECTION_PROMPT.format(
            glossary_section=glossary_section,
            context=context or "(no prior context)",
            text=text,
        )

        try:
            corrected = await self._llm.complete(
                prompt=prompt,
                system=(
                    "You are a transcript correction assistant. "
                    "Return only the corrected text, no explanations."
                ),
                max_tokens=512,
            )
            corrected = corrected.strip().strip('"')

            # Only return if actually different from original
            if corrected and corrected != text:
                logger.info(
                    f"Transcript corrected (confidence={confidence:.2f}): "
                    f"{text[:60]!r} -> {corrected[:60]!r}"
                )
                return corrected

            return None

        except Exception as e:
            logger.error(f"Transcript correction failed: {e}", exc_info=True)
            return None
