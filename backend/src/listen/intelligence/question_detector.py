"""LLM-based question detection from transcript entries."""

from __future__ import annotations

import json
import logging
import time
import uuid
from dataclasses import dataclass
from typing import Optional

from listen.intelligence.llm_client import LLMClient
from listen.transcription.transcript_store import TranscriptStore

logger = logging.getLogger("listen.intelligence.question_detector")

QUESTION_DETECTION_PROMPT = """Analyze the following transcript segment from a meeting.
The last statement was made by {speaker_label}.
Determine if it contains a question that would benefit from a prepared answer.

Transcript context (recent conversation):
{transcript_context}

Latest statement from {speaker_label}:
"{latest_statement}"

Respond with JSON:
{{
  "is_question": true or false,
  "question_text": "the extracted question if is_question is true, else empty string",
  "confidence": 0.0 to 1.0,
  "category": "factual" or "opinion" or "clarification" or "action_item"
}}"""


@dataclass
class DetectedQuestion:
    question_id: str
    question_text: str
    source_turn_id: str
    confidence: float
    category: str
    timestamp: float


class QuestionDetector:
    """Detects questions from any transcript speaker using an LLM."""

    def __init__(
        self,
        llm_client: LLMClient,
        transcript_store: TranscriptStore,
        confidence_threshold: float = 0.7,
        context_window_turns: int = 10,
    ) -> None:
        self.llm_client = llm_client
        self.transcript_store = transcript_store
        self.confidence_threshold = confidence_threshold
        self.context_window_turns = context_window_turns
        self._last_detection_time: dict[str, float] = {}  # Per-speaker rate limiting
        self._min_detection_interval: float = 3.0  # Rate limit: max 1 per 3 seconds per speaker

    async def check_for_question(
        self, turn_id: str, text: str, speaker: str = "them"
    ) -> Optional[DetectedQuestion]:
        """Check if a finalized transcript turn contains a question.

        Returns a DetectedQuestion if one is found above the confidence threshold.
        """
        now = time.time()
        last_time = self._last_detection_time.get(speaker, 0.0)
        if now - last_time < self._min_detection_interval:
            logger.debug(f"Question detection rate-limited for speaker={speaker}")
            return None
        self._last_detection_time[speaker] = now
        logger.debug(f"Checking for question: speaker={speaker}, turn_id={turn_id}")

        # Build context from recent turns
        recent = await self.transcript_store.get_recent(self.context_window_turns)
        context_lines = []
        for entry in recent:
            speaker_label = "Me" if entry.speaker == "me" else "Them"
            context_lines.append(f"{speaker_label}: {entry.text}")
        transcript_context = "\n".join(context_lines)

        speaker_label = "Me" if speaker == "me" else "Them"
        prompt = QUESTION_DETECTION_PROMPT.format(
            transcript_context=transcript_context,
            latest_statement=text,
            speaker_label=speaker_label,
        )

        try:
            response = await self.llm_client.complete(
                prompt=prompt,
                system="You are a meeting analysis assistant. Respond only with valid JSON.",
                json_mode=True,
                max_tokens=256,
            )

            result = json.loads(response)

            is_question = result.get("is_question", False)
            confidence = result.get("confidence", 0)
            logger.info(
                f"Question detection result: is_question={is_question}, "
                f"confidence={confidence:.2f}, speaker={speaker}"
            )

            if is_question and confidence >= self.confidence_threshold:
                question = DetectedQuestion(
                    question_id=f"q_{uuid.uuid4().hex[:12]}",
                    question_text=result.get("question_text", text),
                    source_turn_id=turn_id,
                    confidence=confidence,
                    category=result.get("category", "factual"),
                    timestamp=time.time(),
                )
                logger.info(
                    f"Question detected: id={question.question_id}, "
                    f"category={question.category}, confidence={confidence:.2f}"
                )
                return question

        except json.JSONDecodeError:
            logger.warning("Failed to parse question detection response as JSON")
        except Exception as e:
            logger.error(f"Question detection failed: {e}", exc_info=True)

        return None
