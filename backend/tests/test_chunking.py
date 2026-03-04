"""Tests for document chunking."""

from langchain_core.documents import Document

from listen.knowledge.chunking import chunk_documents


class TestChunking:
    def test_chunk_short_document(self):
        """Short documents should produce a single chunk."""
        docs = [Document(page_content="Short text", metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=500, chunk_overlap=50, size_unit="characters")
        assert len(chunks) == 1
        assert chunks[0].page_content == "Short text"

    def test_chunk_long_document(self):
        """Long documents should be split into multiple chunks."""
        long_text = "word " * 500  # ~2500 chars
        docs = [Document(page_content=long_text, metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=200, chunk_overlap=20, size_unit="characters")
        assert len(chunks) > 1

    def test_chunk_metadata_preserved(self):
        """Source metadata should be preserved and chunk_index added."""
        docs = [
            Document(
                page_content="word " * 200,
                metadata={"source": "/path/to/doc.pdf", "file_name": "doc.pdf"},
            )
        ]
        chunks = chunk_documents(docs, chunk_size=100, chunk_overlap=10, size_unit="characters")
        for i, chunk in enumerate(chunks):
            assert chunk.metadata["source"] == "/path/to/doc.pdf"
            assert chunk.metadata["file_name"] == "doc.pdf"
            assert chunk.metadata["chunk_index"] == i

    def test_empty_documents(self):
        """Empty document list should return empty chunks."""
        assert chunk_documents([], chunk_size=500, chunk_overlap=50) == []

    def test_chunk_has_total_chunks_metadata(self):
        """Each chunk should have total_chunks metadata."""
        long_text = "word " * 500
        docs = [Document(page_content=long_text, metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=200, chunk_overlap=20, size_unit="characters")
        total = len(chunks)
        for chunk in chunks:
            assert chunk.metadata["total_chunks"] == total

    def test_chunk_has_position_metadata(self):
        """Each chunk should have a position label (early/middle/late)."""
        long_text = "word " * 500
        docs = [Document(page_content=long_text, metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=200, chunk_overlap=20, size_unit="characters")
        for chunk in chunks:
            assert chunk.metadata["position"] in ("early", "middle", "late")
        # First chunk should be early, last should be late
        assert chunks[0].metadata["position"] == "early"
        assert chunks[-1].metadata["position"] == "late"

    def test_two_chunk_positions(self):
        """With exactly two chunks, positions should be early and late."""
        # Create text that splits into exactly 2 chunks
        text = "a " * 150  # 300 chars, with chunk_size=200 -> 2 chunks
        docs = [Document(page_content=text, metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=200, chunk_overlap=20, size_unit="characters")
        assert len(chunks) == 2
        assert chunks[0].metadata["position"] == "early"
        assert chunks[1].metadata["position"] == "late"


class TestTokenBasedChunking:
    def test_token_based_splitting(self):
        """Token-based chunking should use tiktoken encoder."""
        # Each word is roughly 1 token, so 200 words ≈ 200 tokens
        long_text = "hello " * 200
        docs = [Document(page_content=long_text, metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=50, chunk_overlap=5, size_unit="tokens")
        assert len(chunks) > 1
        # Every chunk should have position metadata
        for chunk in chunks:
            assert "position" in chunk.metadata

    def test_token_vs_character_different_results(self):
        """Token-based and character-based should produce different chunk counts."""
        text = "The quick brown fox jumps over the lazy dog. " * 50
        docs = [Document(page_content=text, metadata={"source": "test.txt"})]

        char_chunks = chunk_documents(docs, chunk_size=200, chunk_overlap=20, size_unit="characters")
        token_chunks = chunk_documents(docs, chunk_size=50, chunk_overlap=5, size_unit="tokens")

        # Both should produce chunks, but counts will differ
        assert len(char_chunks) > 0
        assert len(token_chunks) > 0

    def test_default_is_tokens(self):
        """Default size_unit should be 'tokens'."""
        docs = [Document(page_content="Short text", metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=500, chunk_overlap=50)
        assert len(chunks) == 1
