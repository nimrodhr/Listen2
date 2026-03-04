"""Document text cleaning and preprocessing before chunking."""

from __future__ import annotations

import logging
import re

from langchain_core.documents import Document

logger = logging.getLogger("listen.knowledge.preprocessing")

# Patterns for common PDF noise
_PAGE_NUMBER_PATTERNS = [
    re.compile(r"^\s*(?:Page\s+)?\d+\s*(?:of\s+\d+)?\s*$", re.IGNORECASE),
    re.compile(r"^\s*-\s*\d+\s*-\s*$"),
    re.compile(r"^\s*\d+\s*$"),
]

_HEADER_FOOTER_PATTERNS = [
    re.compile(r"^\s*(?:confidential|proprietary|draft|internal)\s*$", re.IGNORECASE),
    re.compile(r"^\s*©.*\d{4}.*$"),
    re.compile(r"^\s*All rights reserved\.?\s*$", re.IGNORECASE),
]

_WHITESPACE_COLLAPSE = re.compile(r"\n{3,}")
_TRAILING_SPACES = re.compile(r"[ \t]+$", re.MULTILINE)


def clean_text(text: str) -> str:
    """Clean document text by removing common noise patterns."""
    lines = text.split("\n")
    cleaned = []
    for line in lines:
        # Skip standalone page numbers
        if any(p.match(line) for p in _PAGE_NUMBER_PATTERNS):
            continue
        # Skip common header/footer boilerplate
        if any(p.match(line) for p in _HEADER_FOOTER_PATTERNS):
            continue
        cleaned.append(line)

    result = "\n".join(cleaned)

    # Collapse excessive blank lines
    result = _WHITESPACE_COLLAPSE.sub("\n\n", result)
    # Remove trailing whitespace per line
    result = _TRAILING_SPACES.sub("", result)

    return result.strip()


def preprocess_documents(documents: list[Document]) -> list[Document]:
    """Clean all documents, removing PDF noise and normalizing whitespace."""
    processed = []
    for doc in documents:
        cleaned = clean_text(doc.page_content)
        if not cleaned:
            logger.debug(f"Document chunk empty after cleaning, skipping: {doc.metadata.get('source', '?')}")
            continue
        processed.append(
            Document(page_content=cleaned, metadata=doc.metadata.copy())
        )

    removed = len(documents) - len(processed)
    if removed:
        logger.info(f"Preprocessing: removed {removed} empty chunks from {len(documents)} documents")
    return processed
