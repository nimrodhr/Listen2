"""RAG pipeline: embed question -> search ChromaDB -> generate answer."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from listen.intelligence.llm_client import LLMClient
from listen.knowledge.vector_store import VectorStore

logger = logging.getLogger("listen.intelligence.rag_engine")

RAG_ANSWER_PROMPT = """You are a meeting assistant helping someone answer a question during a live meeting.
Based on the following context from their knowledge base, provide a concise, accurate answer they can use immediately.

Context from knowledge base:
{context_chunks}

Question asked during meeting:
"{question}"

Provide a direct, concise answer (2-4 sentences max).
If the context doesn't contain relevant information, say "I couldn't find relevant information in the knowledge base."
"""


@dataclass
class RAGResult:
    answer: str
    sources: list[dict] = field(default_factory=list)
    has_answer: bool = True


class RAGEngine:
    """Retrieval-Augmented Generation engine for answering meeting questions."""

    def __init__(
        self,
        llm_client: LLMClient,
        vector_store: VectorStore,
        top_k: int = 5,
    ) -> None:
        self.llm_client = llm_client
        self.vector_store = vector_store
        self.top_k = top_k

    async def answer_question(self, question_text: str) -> RAGResult:
        """Find relevant KB chunks and generate an answer."""
        logger.info(f"RAG query: \"{question_text[:80]}\"")

        # Step 1: Search the vector store
        matches = self.vector_store.query(question_text, n_results=self.top_k)

        if not matches:
            logger.info("RAG: no matching chunks found in vector store")
            return RAGResult(
                answer="",
                has_answer=False,
            )

        # Step 2: Build context from retrieved chunks (deduplicate sources by file)
        context_parts = []
        sources = []
        seen_files: set[str] = set()
        for match in matches:
            context_parts.append(
                f"[From {match['file_name']}]: {match['text']}"
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
        logger.info(f"RAG: retrieved {len(matches)} chunks from {len(sources)} sources")

        # Step 3: Generate answer using LLM
        prompt = RAG_ANSWER_PROMPT.format(
            context_chunks=context_str,
            question=question_text,
        )

        try:
            answer = await self.llm_client.complete(
                prompt=prompt,
                max_tokens=512,
            )

            # Check if the LLM said it couldn't find info
            no_info_phrases = [
                "couldn't find relevant",
                "no relevant information",
                "not enough information",
                "don't have information",
            ]
            has_answer = not any(
                phrase in answer.lower() for phrase in no_info_phrases
            )

            logger.info(f"RAG result: has_answer={has_answer}, sources={len(sources)}")
            return RAGResult(
                answer=answer.strip(),
                sources=sources,
                has_answer=has_answer,
            )

        except Exception as e:
            logger.error(f"RAG answer generation failed: {e}", exc_info=True)
            return RAGResult(
                answer="",
                has_answer=False,
            )
