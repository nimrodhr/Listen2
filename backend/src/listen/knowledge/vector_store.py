"""ChromaDB vector store wrapper with hybrid search, filtering, and multi-collection."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

import chromadb
from langchain_core.documents import Document

from listen.knowledge.embeddings import get_embedding_function

logger = logging.getLogger("listen.knowledge.vector_store")

DEFAULT_COLLECTION = "knowledge_base"


class VectorStore:
    """Wrapper around ChromaDB with hybrid search, metadata filtering, and multi-collection."""

    def __init__(
        self,
        persist_path: str = "~/.listen/chromadb",
        embedding_model: str = "text-embedding-3-small",
        api_key: str = "",
        collection_name: str = DEFAULT_COLLECTION,
    ) -> None:
        resolved_path = str(Path(persist_path).expanduser())
        Path(resolved_path).mkdir(parents=True, exist_ok=True)

        self._client = chromadb.PersistentClient(path=resolved_path)
        self._embedding_model = embedding_model
        self._embedding_fn = get_embedding_function(embedding_model, api_key=api_key)
        self._collection_name = collection_name

        self._collection = self._get_or_create_collection(collection_name)

        # BM25 index state (lazily built)
        self._bm25_index = None
        self._bm25_corpus_ids: list[str] = []
        self._bm25_dirty = True

    def _get_or_create_collection(self, name: str):
        """Get or create a ChromaDB collection, handling embedding conflicts."""
        try:
            return self._client.get_or_create_collection(
                name=name,
                embedding_function=self._embedding_fn,
            )
        except Exception as e:
            if "embedding" in str(e).lower():
                logger.warning(
                    f"Embedding function conflict detected, resetting collection: {e}"
                )
                self._client.delete_collection(name)
                return self._client.get_or_create_collection(
                    name=name,
                    embedding_function=self._embedding_fn,
                )
            raise

    # --- Collection management ---

    def switch_collection(self, name: str) -> None:
        """Switch to a different collection (creates if needed)."""
        self._collection = self._get_or_create_collection(name)
        self._collection_name = name
        self._bm25_dirty = True
        logger.info(f"Switched to collection: {name}")

    def list_collections(self) -> list[str]:
        """List all collection names in this ChromaDB instance."""
        return [c.name for c in self._client.list_collections()]

    def delete_collection(self, name: str) -> None:
        """Delete a collection by name."""
        if name == self._collection_name:
            logger.warning("Deleting the active collection — switching to default")
        self._client.delete_collection(name)
        if name == self._collection_name:
            self._collection = self._get_or_create_collection(DEFAULT_COLLECTION)
            self._collection_name = DEFAULT_COLLECTION
            self._bm25_dirty = True
        logger.info(f"Deleted collection: {name}")

    # --- Document operations ---

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
                "total_chunks": chunk.metadata.get("total_chunks", -1),
                "position": chunk.metadata.get("position", ""),
            })

        self._collection.upsert(
            ids=ids,
            documents=documents,
            metadatas=metadatas,
        )
        self._bm25_dirty = True
        logger.info(f"Added {len(chunks)} chunks to collection '{self._collection_name}'")

    def query(
        self,
        query_text: str,
        n_results: int = 5,
        source_filter: Optional[str] = None,
        file_name_filter: Optional[str] = None,
        similarity_threshold: Optional[float] = None,
    ) -> list[dict]:
        """Query the vector store for relevant chunks.

        Args:
            query_text: The query to search for.
            n_results: Max number of results.
            source_filter: If set, only return chunks from this source path.
            file_name_filter: If set, only return chunks from this file name.
            similarity_threshold: If set, exclude chunks with distance > threshold.
        """
        count = self._collection.count()
        if count == 0:
            return []
        n = min(n_results, count)

        # Build metadata filter
        where = self._build_where_filter(source_filter, file_name_filter)

        query_kwargs = {
            "query_texts": [query_text],
            "n_results": n,
        }
        if where:
            query_kwargs["where"] = where

        results = self._collection.query(**query_kwargs)

        matches = []
        if results and results["documents"]:
            for i in range(len(results["documents"][0])):
                distance = results["distances"][0][i] if results["distances"] else None
                # Apply similarity threshold
                if similarity_threshold is not None and distance is not None:
                    if distance > similarity_threshold:
                        continue

                meta = results["metadatas"][0][i] if results["metadatas"] else {}
                matches.append({
                    "text": results["documents"][0][i],
                    "source": meta.get("source", ""),
                    "file_name": meta.get("file_name", ""),
                    "page": meta.get("page"),
                    "chunk_index": meta.get("chunk_index"),
                    "distance": distance,
                    "id": results["ids"][0][i] if results["ids"] else None,
                })

        return matches

    def hybrid_query(
        self,
        query_text: str,
        n_results: int = 20,
        source_filter: Optional[str] = None,
        file_name_filter: Optional[str] = None,
        similarity_threshold: Optional[float] = None,
    ) -> list[dict]:
        """Hybrid search combining vector similarity and BM25 keyword scoring.

        Returns merged results ranked by reciprocal rank fusion (RRF).
        """
        # Vector search
        vector_results = self.query(
            query_text,
            n_results=n_results,
            source_filter=source_filter,
            file_name_filter=file_name_filter,
            similarity_threshold=similarity_threshold,
        )

        # BM25 search
        bm25_results = self._bm25_search(
            query_text,
            n_results=n_results,
            source_filter=source_filter,
            file_name_filter=file_name_filter,
        )

        # Merge with reciprocal rank fusion
        merged = self._reciprocal_rank_fusion(vector_results, bm25_results, k=60)

        # Apply similarity threshold on the merged results
        if similarity_threshold is not None:
            merged = [m for m in merged if m.get("distance") is None or m["distance"] <= similarity_threshold]

        return merged[:n_results]

    # --- BM25 support ---

    def _build_bm25_index(self) -> None:
        """Build or rebuild the BM25 index over the current collection."""
        from rank_bm25 import BM25Okapi

        all_data = self._collection.get()
        if not all_data or not all_data["documents"]:
            self._bm25_index = None
            self._bm25_corpus_ids = []
            self._bm25_dirty = False
            return

        corpus = []
        self._bm25_corpus_ids = all_data["ids"]
        for doc in all_data["documents"]:
            corpus.append(doc.lower().split())

        self._bm25_index = BM25Okapi(corpus)
        self._bm25_dirty = False
        logger.debug(f"BM25 index built with {len(corpus)} documents")

    def _bm25_search(
        self,
        query_text: str,
        n_results: int = 20,
        source_filter: Optional[str] = None,
        file_name_filter: Optional[str] = None,
    ) -> list[dict]:
        """Search using BM25 keyword matching."""
        if self._bm25_dirty or self._bm25_index is None:
            self._build_bm25_index()

        if self._bm25_index is None or not self._bm25_corpus_ids:
            return []

        tokenized_query = query_text.lower().split()
        scores = self._bm25_index.get_scores(tokenized_query)

        # Get top N indices by BM25 score
        scored_indices = sorted(
            enumerate(scores), key=lambda x: x[1], reverse=True
        )[:n_results * 2]  # Get extra for filtering

        # Fetch the actual documents for the top results
        top_ids = [self._bm25_corpus_ids[idx] for idx, score in scored_indices if score > 0]
        if not top_ids:
            return []

        # Fetch chunk data
        fetched = self._collection.get(ids=top_ids[:n_results])
        if not fetched or not fetched["documents"]:
            return []

        results = []
        for i, doc_id in enumerate(fetched["ids"]):
            meta = fetched["metadatas"][i] if fetched["metadatas"] else {}

            # Apply metadata filters
            if source_filter and meta.get("source") != source_filter:
                continue
            if file_name_filter and meta.get("file_name") != file_name_filter:
                continue

            results.append({
                "text": fetched["documents"][i],
                "source": meta.get("source", ""),
                "file_name": meta.get("file_name", ""),
                "page": meta.get("page"),
                "chunk_index": meta.get("chunk_index"),
                "distance": None,  # BM25 doesn't produce distances
                "id": doc_id,
            })

        return results[:n_results]

    @staticmethod
    def _reciprocal_rank_fusion(
        vector_results: list[dict],
        bm25_results: list[dict],
        k: int = 60,
    ) -> list[dict]:
        """Merge two result lists using Reciprocal Rank Fusion (RRF)."""
        scores: dict[str, float] = {}
        chunk_map: dict[str, dict] = {}

        # Score vector results
        for rank, chunk in enumerate(vector_results):
            key = chunk.get("id") or f"{chunk['source']}_{chunk.get('chunk_index', rank)}"
            scores[key] = scores.get(key, 0.0) + 1.0 / (k + rank + 1)
            chunk_map[key] = chunk

        # Score BM25 results
        for rank, chunk in enumerate(bm25_results):
            key = chunk.get("id") or f"{chunk['source']}_{chunk.get('chunk_index', rank)}"
            scores[key] = scores.get(key, 0.0) + 1.0 / (k + rank + 1)
            if key not in chunk_map:
                chunk_map[key] = chunk

        # Sort by fused score
        ranked_keys = sorted(scores, key=lambda k: scores[k], reverse=True)
        return [chunk_map[key] for key in ranked_keys if key in chunk_map]

    # --- Metadata filter helpers ---

    @staticmethod
    def _build_where_filter(
        source_filter: Optional[str] = None,
        file_name_filter: Optional[str] = None,
    ) -> Optional[dict]:
        """Build a ChromaDB where clause from optional filters."""
        conditions = []
        if source_filter:
            conditions.append({"source": source_filter})
        if file_name_filter:
            conditions.append({"file_name": file_name_filter})

        if not conditions:
            return None
        if len(conditions) == 1:
            return conditions[0]
        return {"$and": conditions}

    # --- Existing methods ---

    def delete_by_source(self, source_path: str) -> None:
        """Remove all chunks from a specific source file."""
        results = self._collection.get(where={"source": source_path})
        if results and results["ids"]:
            self._collection.delete(ids=results["ids"])
            self._bm25_dirty = True
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
        self._client.delete_collection(self._collection_name)
        self._collection = self._get_or_create_collection(self._collection_name)
        self._bm25_dirty = True
        logger.info("Vector store flushed")

    def get_stats(self) -> dict:
        """Get vector store statistics."""
        count = self._collection.count()
        sources = self.list_sources()
        collections = self.list_collections()
        return {
            "total_chunks": count,
            "total_documents": len(sources),
            "sources": sources,
            "index_health": "healthy" if count > 0 else "empty",
            "embedding_model": self._embedding_model,
            "vector_db_type": "chromadb",
            "collection": self._collection_name,
            "collections": collections,
        }
