"""Text splitting for knowledge base documents."""

from __future__ import annotations

import logging

from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_core.documents import Document

logger = logging.getLogger("listen.knowledge.chunking")


def _token_length(text: str) -> int:
    """Count tokens using tiktoken (cl100k_base, used by OpenAI models)."""
    try:
        import tiktoken
        enc = tiktoken.get_encoding("cl100k_base")
        return len(enc.encode(text))
    except ImportError:
        # Fallback: approximate tokens as chars / 4
        return len(text) // 4


def chunk_documents(
    documents: list[Document],
    chunk_size: int = 500,
    chunk_overlap: int = 50,
    size_unit: str = "tokens",
) -> list[Document]:
    """Split documents into smaller chunks for embedding.

    Args:
        documents: List of LangChain Documents to split.
        chunk_size: Maximum chunk size.
        chunk_overlap: Overlap between consecutive chunks.
        size_unit: "tokens" for token-based sizing, "characters" for char-based.
    """
    if size_unit == "tokens":
        splitter = RecursiveCharacterTextSplitter.from_tiktoken_encoder(
            encoding_name="cl100k_base",
            chunk_size=chunk_size,
            chunk_overlap=chunk_overlap,
            separators=["\n\n", "\n", ". ", " ", ""],
        )
    else:
        splitter = RecursiveCharacterTextSplitter(
            chunk_size=chunk_size,
            chunk_overlap=chunk_overlap,
            separators=["\n\n", "\n", ". ", " ", ""],
        )

    chunks = splitter.split_documents(documents)

    total = len(chunks)
    for i, chunk in enumerate(chunks):
        chunk.metadata["chunk_index"] = i
        chunk.metadata["total_chunks"] = total
        # Position hint: early/middle/late in the document
        if total <= 2:
            chunk.metadata["position"] = "early" if i == 0 else "late"
        elif i < total / 3:
            chunk.metadata["position"] = "early"
        elif i < 2 * total / 3:
            chunk.metadata["position"] = "middle"
        else:
            chunk.metadata["position"] = "late"

    logger.info(f"Split {len(documents)} documents into {total} chunks (unit={size_unit})")
    return chunks
