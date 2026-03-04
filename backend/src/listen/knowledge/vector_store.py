"""ChromaDB vector store wrapper for knowledge base."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

import chromadb
from langchain_core.documents import Document

from listen.knowledge.embeddings import get_embedding_function

logger = logging.getLogger("listen.knowledge.vector_store")

COLLECTION_NAME = "knowledge_base"


class VectorStore:
    """Wrapper around ChromaDB for storing and querying document embeddings."""

    def __init__(
        self,
        persist_path: str = "~/.listen/chromadb",
        embedding_model: str = "text-embedding-3-small",
        api_key: str = "",
    ) -> None:
        resolved_path = str(Path(persist_path).expanduser())
        Path(resolved_path).mkdir(parents=True, exist_ok=True)

        self._client = chromadb.PersistentClient(path=resolved_path)
        self._embedding_model = embedding_model
        self._embedding_fn = get_embedding_function(embedding_model, api_key=api_key)
        try:
            self._collection = self._client.get_or_create_collection(
                name=COLLECTION_NAME,
                embedding_function=self._embedding_fn,
            )
        except Exception as e:
            if "embedding function" in str(e).lower() or "embedding_function" in str(e).lower():
                # Embedding model changed — delete old collection and recreate
                logger.warning(
                    f"Embedding function conflict detected, resetting collection: {e}"
                )
                self._client.delete_collection(COLLECTION_NAME)
                self._collection = self._client.get_or_create_collection(
                    name=COLLECTION_NAME,
                    embedding_function=self._embedding_fn,
                )
            else:
                raise

    def add_documents(self, chunks: list[Document]) -> None:
        """Add document chunks to the vector store."""
        if not chunks:
            return

        ids = []
        documents = []
        metadatas = []

        for i, chunk in enumerate(chunks):
            chunk_id = f"{chunk.metadata.get('source', 'unknown')}_{chunk.metadata.get('chunk_index', i)}"
            ids.append(chunk_id)
            documents.append(chunk.page_content)
            metadatas.append({
                "source": chunk.metadata.get("source", ""),
                "file_name": chunk.metadata.get("file_name", ""),
                "page": chunk.metadata.get("page", -1),
                "chunk_index": chunk.metadata.get("chunk_index", i),
            })

        self._collection.upsert(
            ids=ids,
            documents=documents,
            metadatas=metadatas,
        )
        logger.info(f"Added {len(chunks)} chunks to vector store")

    def query(
        self, query_text: str, n_results: int = 5
    ) -> list[dict]:
        """Query the vector store for relevant chunks."""
        count = self._collection.count()
        if count == 0:
            return []
        n = min(n_results, count)

        results = self._collection.query(
            query_texts=[query_text],
            n_results=n,
        )

        matches = []
        if results and results["documents"]:
            for i in range(len(results["documents"][0])):
                meta = results["metadatas"][0][i] if results["metadatas"] else {}
                matches.append({
                    "text": results["documents"][0][i],
                    "source": meta.get("source", ""),
                    "file_name": meta.get("file_name", ""),
                    "page": meta.get("page"),
                    "distance": results["distances"][0][i] if results["distances"] else None,
                })

        return matches

    def delete_by_source(self, source_path: str) -> None:
        """Remove all chunks from a specific source file."""
        # Get all IDs with this source
        results = self._collection.get(
            where={"source": source_path},
        )
        if results and results["ids"]:
            self._collection.delete(ids=results["ids"])
            logger.info(f"Deleted {len(results['ids'])} chunks from {source_path}")

    def list_sources(self) -> list[dict]:
        """List all indexed source files with chunk counts."""
        all_data = self._collection.get()
        if not all_data or not all_data["metadatas"]:
            return []

        source_counts: dict[str, dict] = {}
        for meta in all_data["metadatas"]:
            source = meta.get("source", "unknown")
            if source not in source_counts:
                source_counts[source] = {
                    "file_name": meta.get("file_name", ""),
                    "source": source,
                    "chunks": 0,
                }
            source_counts[source]["chunks"] += 1

        return list(source_counts.values())

    def flush(self) -> None:
        """Remove all documents from the collection."""
        self._client.delete_collection(COLLECTION_NAME)
        self._collection = self._client.get_or_create_collection(
            name=COLLECTION_NAME,
            embedding_function=self._embedding_fn,
        )
        logger.info("Vector store flushed")

    def get_stats(self) -> dict:
        """Get vector store statistics."""
        count = self._collection.count()
        sources = self.list_sources()
        return {
            "total_chunks": count,
            "total_documents": len(sources),
            "sources": sources,
            "index_health": "healthy" if count > 0 else "empty",
            "embedding_model": self._embedding_model,
            "vector_db_type": "chromadb",
        }
