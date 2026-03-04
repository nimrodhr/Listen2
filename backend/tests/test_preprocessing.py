"""Tests for document preprocessing."""

from langchain_core.documents import Document

from listen.knowledge.preprocessing import clean_text, preprocess_documents


class TestCleanText:
    def test_removes_page_numbers(self):
        text = "Some content\n42\nMore content\nPage 3 of 10\n"
        result = clean_text(text)
        assert "42" not in result.split("\n")
        assert "Page 3 of 10" not in result
        assert "Some content" in result
        assert "More content" in result

    def test_removes_standalone_page_numbers(self):
        text = "   5   \nActual content here"
        result = clean_text(text)
        assert "Actual content here" in result

    def test_removes_copyright_lines(self):
        text = "Content here\n© 2024 Acme Corp\nMore content"
        result = clean_text(text)
        assert "© 2024 Acme Corp" not in result
        assert "Content here" in result

    def test_removes_confidential_boilerplate(self):
        text = "Content\n  Confidential  \nMore content"
        result = clean_text(text)
        assert "Confidential" not in result

    def test_collapses_excessive_blank_lines(self):
        text = "First\n\n\n\n\n\nSecond"
        result = clean_text(text)
        assert "\n\n\n" not in result
        assert "First" in result
        assert "Second" in result

    def test_preserves_meaningful_content(self):
        text = "Title\n\nParagraph one.\n\nParagraph two."
        result = clean_text(text)
        assert result == text

    def test_strips_trailing_whitespace(self):
        text = "line one   \nline two\t\t"
        result = clean_text(text)
        assert "   " not in result
        assert "\t" not in result

    def test_empty_input(self):
        assert clean_text("") == ""
        assert clean_text("   ") == ""


class TestPreprocessDocuments:
    def test_removes_empty_docs_after_cleaning(self):
        docs = [
            Document(page_content="42", metadata={"source": "a.pdf"}),
            Document(page_content="Real content", metadata={"source": "b.pdf"}),
        ]
        result = preprocess_documents(docs)
        assert len(result) == 1
        assert result[0].page_content == "Real content"

    def test_preserves_metadata(self):
        docs = [
            Document(page_content="Content here", metadata={"source": "test.pdf", "page": 1}),
        ]
        result = preprocess_documents(docs)
        assert result[0].metadata["source"] == "test.pdf"
        assert result[0].metadata["page"] == 1

    def test_empty_list(self):
        assert preprocess_documents([]) == []
