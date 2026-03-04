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
            "embedding": "all-MiniLM-L6-v2",
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
            "chromadb_path": "/tmp/test_chromadb",
        },
        "question_detection": {
            "confidence_threshold": 0.7,
            "context_window_turns": 10,
            "context_window_seconds": 60,
        },
        "rag": {"top_k": 5, "max_answer_length": 200},
        "server": {"ws_port": 8765, "ws_host": "127.0.0.1"},
    }
