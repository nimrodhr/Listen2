"""Settings schema and persistence for Listen."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, Field

logger = logging.getLogger("listen.config")


LISTEN_DIR = Path.home() / ".listen"
SETTINGS_FILE = LISTEN_DIR / "settings.json"


class ApiKeysConfig(BaseModel):
    openai: str = ""


class ModelsConfig(BaseModel):
    transcription: str = "gpt-4o-transcribe"
    question_detection: str = "gpt-4o-mini"
    rag_answer: str = "gpt-4o"
    embedding: str = "text-embedding-3-small"


class AudioConfig(BaseModel):
    mic_device_id: Optional[int] = None
    system_device_id: Optional[int] = None
    sample_rate: int = 24000
    chunk_duration_ms: int = 100


class TranscriptionConfig(BaseModel):
    language: str = "en"
    prompt: str = (
        "This is a meeting conversation in English. "
        "Transcribe only English speech. "
        "Ignore any non-English words or background noise. "
        "If speech is unclear, prefer English interpretations."
    )
    glossary: list[str] = Field(default_factory=list)
    vad_threshold: float = 0.5
    vad_prefix_padding_ms: int = 300
    vad_silence_duration_ms: int = 500
    noise_reduction: str = "near_field"


class NormalizationConfig(BaseModel):
    enabled: bool = True
    strip_fillers: bool = True
    fillers: list[str] = Field(
        default_factory=lambda: [
            "um", "uh", "hmm", "you know", "like", "so", "I mean", "right",
        ]
    )


class CorrectionConfig(BaseModel):
    enabled: bool = False
    model: str = "gpt-4o-mini"
    correct_all: bool = False  # If false, only correct low-confidence turns
    confidence_threshold: float = 0.7  # Correct turns below this confidence


class KnowledgeBaseConfig(BaseModel):
    directory: str = ""
    chunk_size: int = 1500
    chunk_overlap: int = 200
    chunk_size_unit: str = "tokens"  # "tokens" or "characters"
    chromadb_path: str = str(LISTEN_DIR / "chromadb")
    default_collection: str = "knowledge_base"
    preprocess_documents: bool = True
    auto_ingest_transcripts: bool = False


class QuestionDetectionConfig(BaseModel):
    confidence_threshold: float = 0.7
    context_window_turns: int = 10
    context_window_seconds: int = 60


class RagConfig(BaseModel):
    top_k: int = 10
    max_answer_length: int = 200
    similarity_threshold: float = 1.5  # Max ChromaDB distance; lower = stricter
    use_reranker: bool = True
    reranker_candidates: int = 20  # Retrieve this many before reranking
    reranker_top_n: int = 5  # Keep top N after reranking
    hybrid_search: bool = True  # Combine vector + keyword (BM25)
    cache_ttl_seconds: int = 300  # Cache TTL for repeated queries
    query_logging: bool = True  # Log queries for offline analysis


class ServerConfig(BaseModel):
    ws_port: int = 8765
    ws_host: str = "127.0.0.1"


class Settings(BaseModel):
    version: int = 1
    api_keys: ApiKeysConfig = Field(default_factory=ApiKeysConfig)
    models: ModelsConfig = Field(default_factory=ModelsConfig)
    audio: AudioConfig = Field(default_factory=AudioConfig)
    transcription: TranscriptionConfig = Field(default_factory=TranscriptionConfig)
    normalization: NormalizationConfig = Field(default_factory=NormalizationConfig)
    correction: CorrectionConfig = Field(default_factory=CorrectionConfig)
    knowledge_base: KnowledgeBaseConfig = Field(default_factory=KnowledgeBaseConfig)
    question_detection: QuestionDetectionConfig = Field(
        default_factory=QuestionDetectionConfig
    )
    rag: RagConfig = Field(default_factory=RagConfig)
    server: ServerConfig = Field(default_factory=ServerConfig)


def load_settings() -> Settings:
    """Load settings from disk, returning defaults if file doesn't exist."""
    if SETTINGS_FILE.exists():
        try:
            data = json.loads(SETTINGS_FILE.read_text())
            settings = Settings.model_validate(data)
            logger.info(f"Settings loaded from {SETTINGS_FILE}")
            return settings
        except Exception as e:
            logger.error(f"Failed to load settings from {SETTINGS_FILE}: {e}", exc_info=True)
            return Settings()
    logger.info("No settings file found, using defaults")
    return Settings()


def save_settings(settings: Settings) -> None:
    """Persist settings to disk with restricted permissions."""
    try:
        LISTEN_DIR.mkdir(parents=True, exist_ok=True)
        SETTINGS_FILE.write_text(settings.model_dump_json(indent=2))
        os.chmod(SETTINGS_FILE, 0o600)
        logger.info(f"Settings saved to {SETTINGS_FILE}")
    except Exception as e:
        logger.error(f"Failed to save settings: {e}", exc_info=True)
