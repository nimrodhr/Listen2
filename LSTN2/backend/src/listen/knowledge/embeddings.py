"""Embedding function using OpenAI API for ChromaDB."""

from __future__ import annotations

import logging

logger = logging.getLogger("listen.knowledge.embeddings")

DEFAULT_MODEL = "text-embedding-3-small"


def get_embedding_function(model_name: str = DEFAULT_MODEL, api_key: str = ""):
    """Get a ChromaDB-compatible embedding function using OpenAI API."""
    from chromadb.utils.embedding_functions import OpenAIEmbeddingFunction

    if not api_key:
        raise ValueError("OpenAI API key is required for embeddings")

    logger.info(f"Creating embedding function: model={model_name}")
    return OpenAIEmbeddingFunction(
        api_key=api_key,
        model_name=model_name,
    )
