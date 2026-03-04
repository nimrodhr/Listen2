"""Tests for document chunking."""

from langchain_core.documents import Document

from listen.knowledge.chunking import chunk_documents


class TestChunking:
    def test_chunk_short_document(self):
        """Short documents should produce a single chunk."""
        docs = [Document(page_content="Short text", metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=500, chunk_overlap=50)
        assert len(chunks) == 1
        assert chunks[0].page_content == "Short text"

    def test_chunk_long_document(self):
        """Long documents should be split into multiple chunks."""
        long_text = "word " * 500  # ~2500 chars
        docs = [Document(page_content=long_text, metadata={"source": "test.txt"})]
        chunks = chunk_documents(docs, chunk_size=200, chunk_overlap=20)
        assert len(chunks) > 1

    def test_chunk_metadata_preserved(self):
        """Source metadata should be preserved and chunk_index added."""
        docs = [
            Document(
                page_content="word " * 200,
                metadata={"source": "/path/to/doc.pdf", "file_name": "doc.pdf"},
            )
        ]
        chunks = chunk_documents(docs, chunk_size=100, chunk_overlap=10)
        for i, chunk in enumerate(chunks):
            assert chunk.metadata["source"] == "/path/to/doc.pdf"
            assert chunk.metadata["file_name"] == "doc.pdf"
            assert chunk.metadata["chunk_index"] == i

    def test_empty_documents(self):
        """Empty document list should return empty chunks."""
        assert chunk_documents([], chunk_size=500, chunk_overlap=50) == []
