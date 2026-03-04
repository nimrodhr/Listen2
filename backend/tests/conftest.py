"""Shared test fixtures."""

import pytest


@pytest.fixture
def sample_settings_data():
    """Return a minimal valid settings dict."""
    return {
        "version": 1,
        "api_keys": {"openai": "sk-test-key"},
        "models": {
            "transcription": "gpt-4o-transcribe",
            "question_detection": "gpt-4o-mini",
            "rag_answer": "gpt-4o-mini",
            "embedding": "text-embedding-3-small",
        },
        "audio": {
            "mic_device_id": None,
            "system_device_id": None,
            "sample_rate": 24000,
            "chunk_duration_ms": 100,
        },
        "transcription": {
            "language": "en",
            "vad_threshold": 0.5,
            "vad_prefix_padding_ms": 300,
            "vad_silence_duration_ms": 500,
            "noise_reduction": "near_field",
        },
        "knowledge_base": {
            "directory": "",
            "chunk_size": 500,
            "chunk_overlap": 50,
            "chunk_size_unit": "tokens",
            "chromadb_path": "/tmp/test_chromadb",
            "default_collection": "knowledge_base",
            "preprocess_documents": True,
        },
        "question_detection": {
            "confidence_threshold": 0.7,
            "context_window_turns": 10,
            "context_window_seconds": 60,
        },
        "rag": {
            "top_k": 5,
            "max_answer_length": 200,
            "similarity_threshold": 1.5,
            "use_reranker": True,
            "reranker_candidates": 20,
            "reranker_top_n": 5,
            "hybrid_search": True,
            "cache_ttl_seconds": 300,
            "query_logging": False,
        },
        "server": {"ws_port": 8765, "ws_host": "127.0.0.1"},
    }
