"""Document loading from local files (PDF, DOCX, MD, TXT)."""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Iterator

from langchain_community.document_loaders import (
    PyPDFLoader,
    Docx2txtLoader,
    TextLoader,
)
from langchain_core.documents import Document

logger = logging.getLogger("listen.knowledge.ingestion")

SUPPORTED_EXTENSIONS = {".pdf", ".docx", ".md", ".txt"}

LOADER_MAP = {
    ".pdf": PyPDFLoader,
    ".docx": Docx2txtLoader,
    ".md": TextLoader,
    ".txt": TextLoader,
}


def load_document(file_path: str) -> list[Document]:
    """Load a single document file and return LangChain Documents."""
    path = Path(file_path)
    ext = path.suffix.lower()

    if ext not in LOADER_MAP:
        logger.warning(f"Unsupported file type: {ext} ({file_path})")
        return []

    loader_cls = LOADER_MAP[ext]
    try:
        loader = loader_cls(str(path))
        docs = loader.load()
        # Add source metadata
        for doc in docs:
            doc.metadata["source"] = str(path)
            doc.metadata["file_name"] = path.name
        return docs
    except Exception as e:
        logger.error(f"Failed to load {file_path}: {e}", exc_info=True)
        return []


def scan_directory(directory: str) -> Iterator[Path]:
    """Yield all supported document files in a directory."""
    dir_path = Path(directory)
    if not dir_path.is_dir():
        logger.error(f"Not a directory: {directory}")
        return

    for ext in SUPPORTED_EXTENSIONS:
        yield from dir_path.rglob(f"*{ext}")


def load_directory(directory: str) -> list[Document]:
    """Load all supported documents from a directory."""
    all_docs = []
    for file_path in scan_directory(directory):
        docs = load_document(str(file_path))
        all_docs.extend(docs)
        logger.info(f"Loaded {len(docs)} pages from {file_path.name}")
    logger.info(f"Total: {len(all_docs)} pages from {directory}")
    return all_docs
