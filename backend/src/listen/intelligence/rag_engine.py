"""RAG pipeline: hybrid search -> rerank -> generate answer with citations."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
from dataclasses import dataclass, field
from typing import Optional

from listen.intelligence.llm_client import LLMClient
from listen.intelligence.reranker import LLMReranker
from listen.intelligence.query_logger import QueryLogger, QueryLogEntry
from listen.knowledge.vector_store import VectorStore

logger = logging.getLogger("listen.intelligence.rag_engine")

RAG_ANSWER_PROMPT = """You are a meeting assistant helping someone answer a question during a live meeting.
Based on the following context from their knowledge base, provide a concise, accurate answer they can use immediately.

Critical guidelines for accuracy:
- Pay VERY close attention to dates, date ranges, and chronological ordering.
- When asked about "last", "latest", "most recent", or "current" experience/role/position:
  1. Look at ALL date ranges across ALL chunks (not just the first chunk).
  2. Compare end dates: "Present", "Now", "Current", or the most recent year = latest entry.
  3. Compare start dates when end dates are the same.
  4. Do NOT assume the first chunk or first entry is the most recent — verify by dates.
- Resumes/CVs often list entries in reverse chronological order (most recent first), but always VERIFY by checking actual date ranges rather than relying on document order.
- Lower chunk numbers = earlier in document, but chronological order depends on dates, not position.
- If multiple roles overlap in time, mention all of them.
- Be precise with dates — don't approximate or guess. Only state dates that appear in the context.

Context from knowledge base (each chunk has an ID like [C0], [C1], etc.):
{context_chunks}

Question asked during meeting:
"{question}"

You MUST respond with a JSON object in this exact format:
{{
  "answer": "Your direct, concise answer (2-4 sentences max). Be factually precise.",
  "confidence": 0.85,
  "citations": [0, 2],
  "has_answer": true
}}

Rules for the JSON response:
- "answer": The answer text. If the context doesn't contain relevant information, set answer to "" and has_answer to false.
- "confidence": A float from 0.0 to 1.0 indicating how confident you are in the answer's accuracy.
- "citations": An array of chunk IDs (integers) that support your answer. Reference only chunks you actually used.
- "has_answer": true if you found relevant information, false otherwise.

Return ONLY the JSON object, no other text."""


@dataclass
class RAGResult:
    answer: str
    sources: list[dict] = field(default_factory=list)
    has_answer: bool = True
    confidence: float = 0.0
    citations: list[int] = field(default_factory=list)


class _QueryCache:
    """Simple TTL cache for RAG query results."""

    def __init__(self, ttl_seconds: int = 300) -> None:
        self._cache: dict[str, tuple[float, RAGResult]] = {}
        self._ttl = ttl_seconds

    def get(self, key: str) -> Optional[RAGResult]:
        entry = self._cache.get(key)
        if entry is None:
            return None
        ts, result = entry
        if time.time() - ts > self._ttl:
            del self._cache[key]
            return None
        return result

    def put(self, key: str, result: RAGResult) -> None:
        self._cache[key] = (time.time(), result)

    def invalidate(self) -> None:
        """Clear all cached results (e.g. after KB update)."""
        self._cache.clear()

    @staticmethod
    def make_key(query: str, top_k: int, collection: str) -> str:
        raw = f"{query}|{top_k}|{collection}"
        return hashlib.md5(raw.encode()).hexdigest()


class RAGEngine:
    """Retrieval-Augmented Generation engine with hybrid search, reranking, and caching."""

    def __init__(
        self,
        llm_client: LLMClient,
        vector_store: VectorStore,
        top_k: int = 5,
        similarity_threshold: float = 1.5,
        use_reranker: bool = True,
        reranker_candidates: int = 20,
        reranker_top_n: int = 5,
        hybrid_search: bool = True,
        cache_ttl_seconds: int = 300,
        query_logging: bool = True,
        reranker_llm_client: Optional[LLMClient] = None,
    ) -> None:
        self.llm_client = llm_client
        self.vector_store = vector_store
        self.top_k = top_k
        self.similarity_threshold = similarity_threshold
        self.hybrid_search = hybrid_search

        # Reranker
        self._reranker: Optional[LLMReranker] = None
        if use_reranker:
            reranker_llm = reranker_llm_client or llm_client
            self._reranker = LLMReranker(
                llm_client=reranker_llm,
                top_n=reranker_top_n,
            )
        self._reranker_candidates = reranker_candidates

        # Cache
        self._cache = _QueryCache(ttl_seconds=cache_ttl_seconds)

        # Query logger
        self._query_logger: Optional[QueryLogger] = None
        if query_logging:
            self._query_logger = QueryLogger()

    async def answer_question(
        self,
        question_text: str,
        source_filter: Optional[str] = None,
        file_name_filter: Optional[str] = None,
    ) -> RAGResult:
        """Find relevant KB chunks and generate an answer with citations."""
        start = time.monotonic()
        logger.info(f"RAG query: \"{question_text[:80]}\"")

        # Check cache
        cache_key = _QueryCache.make_key(
            question_text, self.top_k, self.vector_store._collection_name
        )
        cached = self._cache.get(cache_key)
        if cached is not None:
            logger.info("RAG: cache hit")
            self._log_query(question_text, [], [], cached, start, cache_hit=True)
            return cached

        # Step 1: Retrieve candidates (run in thread to avoid blocking event loop)
        retrieve_n = self._reranker_candidates if self._reranker else self.top_k
        if self.hybrid_search:
            matches = await asyncio.to_thread(
                self.vector_store.hybrid_query,
                question_text,
                n_results=retrieve_n,
                source_filter=source_filter,
                file_name_filter=file_name_filter,
                similarity_threshold=self.similarity_threshold,
            )
        else:
            matches = await asyncio.to_thread(
                self.vector_store.query,
                question_text,
                n_results=retrieve_n,
                source_filter=source_filter,
                file_name_filter=file_name_filter,
                similarity_threshold=self.similarity_threshold,
            )

        if not matches:
            logger.info("RAG: no matching chunks found in vector store")
            result = RAGResult(answer="", has_answer=False)
            self._log_query(question_text, [], [], result, start)
            return result

        retrieved_chunks = list(matches)  # Copy for logging

        # Step 2: Rerank
        if self._reranker:
            matches = await self._reranker.rerank(
                question=question_text,
                chunks=matches,
                top_n=self.top_k,
            )
        else:
            matches = matches[:self.top_k]

        reranked_chunks = list(matches)

        # Step 3: Build context with chunk IDs for citations
        context_parts = []
        sources = []
        seen_files: set[str] = set()
        for idx, match in enumerate(matches):
            page_info = f", page {match['page']}" if match.get('page') is not None and match['page'] >= 0 else ""
            chunk_info = f", chunk {match.get('chunk_index', '?')}" if match.get('chunk_index') is not None else ""
            context_parts.append(
                f"[C{idx}] [From {match['file_name']}{page_info}{chunk_info}]: {match['text']}"
            )
            file_key = match["source"]
            if file_key not in seen_files:
                seen_files.add(file_key)
                sources.append({
                    "file_name": match["file_name"],
                    "file_path": match["source"],
                    "page": match.get("page"),
                    "chunk_preview": match["text"][:150] + "..."
                    if len(match["text"]) > 150
                    else match["text"],
                })

        context_str = "\n\n".join(context_parts)
        logger.info(f"RAG: {len(matches)} chunks from {len(sources)} sources after reranking")

        # Step 4: Generate answer with structured JSON output
        prompt = RAG_ANSWER_PROMPT.format(
            context_chunks=context_str,
            question=question_text,
        )

        try:
            raw_response = await self.llm_client.complete(
                prompt=prompt,
                json_mode=True,
                max_tokens=512,
            )

            result = self._parse_structured_response(raw_response, sources)
            logger.info(
                f"RAG result: has_answer={result.has_answer}, "
                f"confidence={result.confidence:.2f}, "
                f"citations={result.citations}, sources={len(result.sources)}"
            )

            # Cache the result
            self._cache.put(cache_key, result)

            self._log_query(question_text, retrieved_chunks, reranked_chunks, result, start)
            return result

        except Exception as e:
            logger.error(f"RAG answer generation failed: {e}", exc_info=True)
            result = RAGResult(answer="", has_answer=False)
            self._log_query(question_text, retrieved_chunks, reranked_chunks, result, start)
            return result

    def _parse_structured_response(
        self, raw_response: str, sources: list[dict]
    ) -> RAGResult:
        """Parse the LLM's structured JSON response into a RAGResult."""
        try:
            data = json.loads(raw_response)
            answer = data.get("answer", "").strip()
            has_answer = data.get("has_answer", bool(answer))
            confidence = float(data.get("confidence", 0.0))
            citations = data.get("citations", [])

            return RAGResult(
                answer=answer,
                sources=sources,
                has_answer=has_answer,
                confidence=max(0.0, min(1.0, confidence)),
                citations=[int(c) for c in citations],
            )
        except (json.JSONDecodeError, ValueError, TypeError) as e:
            logger.warning(f"Failed to parse structured response, using fallback: {e}")
            # Fallback: treat raw response as plain text answer
            answer = raw_response.strip()
            no_info_phrases = [
                "couldn't find relevant",
                "no relevant information",
                "not enough information",
                "don't have information",
            ]
            has_answer = not any(
                phrase in answer.lower() for phrase in no_info_phrases
            )
            return RAGResult(
                answer=answer,
                sources=sources,
                has_answer=has_answer,
                confidence=0.5 if has_answer else 0.0,
            )

    def _log_query(
        self,
        query: str,
        retrieved: list[dict],
        reranked: list[dict],
        result: RAGResult,
        start_time: float,
        cache_hit: bool = False,
    ) -> None:
        """Log the query and result for offline analysis."""
        if not self._query_logger:
            return

        elapsed_ms = (time.monotonic() - start_time) * 1000

        # Count how many chunks were filtered by threshold
        filtered_count = 0
        for chunk in retrieved:
            dist = chunk.get("distance")
            if dist is not None and dist > self.similarity_threshold:
                filtered_count += 1

        entry = QueryLogEntry(
            timestamp=time.time(),
            query=query,
            collection=self.vector_store._collection_name,
            retrieved_count=len(retrieved),
            retrieved_chunks=[
                {"text": c.get("text", ""), "distance": c.get("distance"), "file_name": c.get("file_name", "")}
                for c in retrieved[:10]  # Cap logged chunks
            ],
            reranked_count=len(reranked),
            reranked_chunks=[
                {"text": c.get("text", ""), "rerank_score": c.get("rerank_score"), "file_name": c.get("file_name", "")}
                for c in reranked[:10]
            ],
            answer=result.answer,
            has_answer=result.has_answer,
            confidence=result.confidence,
            latency_ms=elapsed_ms,
            similarity_threshold=self.similarity_threshold,
            chunks_filtered_by_threshold=filtered_count,
            cache_hit=cache_hit,
        )
        self._query_logger.log(entry)
