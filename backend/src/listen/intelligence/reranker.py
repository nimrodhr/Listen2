"""LLM-based reranker for RAG chunk relevance scoring."""

from __future__ import annotations

import json
import logging
from typing import Optional

from listen.intelligence.llm_client import LLMClient

logger = logging.getLogger("listen.intelligence.reranker")

RERANK_PROMPT = """You are a relevance scoring system. Given a question and a list of text chunks, score each chunk's relevance to answering the question.

Question: "{question}"

Chunks:
{chunks}

For each chunk, assign a relevance score from 0.0 to 1.0 where:
- 1.0 = directly answers the question
- 0.7-0.9 = highly relevant context
- 0.4-0.6 = somewhat relevant
- 0.1-0.3 = tangentially related
- 0.0 = not relevant at all

Return a JSON object with a "scores" array containing objects with "chunk_id" and "score" fields.
Return ONLY the JSON, no other text.

Example response:
{{"scores": [{{"chunk_id": 0, "score": 0.9}}, {{"chunk_id": 1, "score": 0.3}}]}}"""


class LLMReranker:
    """Reranks retrieved chunks using an LLM to score relevance."""

    def __init__(
        self,
        llm_client: LLMClient,
        top_n: int = 5,
    ) -> None:
        self.llm_client = llm_client
        self.top_n = top_n

    async def rerank(
        self,
        question: str,
        chunks: list[dict],
        top_n: Optional[int] = None,
    ) -> list[dict]:
        """Rerank chunks by relevance to the question.

        Args:
            question: The user's question.
            chunks: List of chunk dicts with at least 'text' key.
            top_n: Override for number of top results to return.

        Returns:
            Reranked and filtered list of chunk dicts, with 'rerank_score' added.
        """
        if not chunks:
            return []

        n = top_n or self.top_n
        if len(chunks) <= n:
            # Not enough chunks to warrant reranking; return as-is with neutral scores
            for chunk in chunks:
                chunk["rerank_score"] = 1.0
            return chunks

        # Build chunk list for the prompt
        chunk_texts = []
        for i, chunk in enumerate(chunks):
            text_preview = chunk["text"][:500]  # Limit per-chunk size
            chunk_texts.append(f"[Chunk {i}]: {text_preview}")

        chunks_str = "\n\n".join(chunk_texts)
        prompt = RERANK_PROMPT.format(question=question, chunks=chunks_str)

        try:
            response = await self.llm_client.complete(
                prompt=prompt,
                json_mode=True,
                max_tokens=1024,
            )

            scores = self._parse_scores(response, len(chunks))

            # Attach scores and sort by relevance
            for i, chunk in enumerate(chunks):
                chunk["rerank_score"] = scores.get(i, 0.0)

            ranked = sorted(chunks, key=lambda c: c["rerank_score"], reverse=True)
            result = ranked[:n]

            logger.info(
                f"Reranked {len(chunks)} chunks → top {len(result)}, "
                f"scores: {[round(c['rerank_score'], 2) for c in result]}"
            )
            return result

        except Exception as e:
            logger.warning(f"Reranking failed, returning original order: {e}")
            # Fallback: return first N chunks without reranking
            for chunk in chunks:
                chunk["rerank_score"] = 1.0
            return chunks[:n]

    def _parse_scores(self, response: str, num_chunks: int) -> dict[int, float]:
        """Parse the LLM's JSON response into a chunk_id → score mapping."""
        try:
            data = json.loads(response)
            scores = {}
            for entry in data.get("scores", []):
                chunk_id = int(entry["chunk_id"])
                score = float(entry["score"])
                scores[chunk_id] = max(0.0, min(1.0, score))
            return scores
        except (json.JSONDecodeError, KeyError, ValueError) as e:
            logger.warning(f"Failed to parse reranker response: {e}")
            # Fallback: all chunks get equal score
            return {i: 0.5 for i in range(num_chunks)}
