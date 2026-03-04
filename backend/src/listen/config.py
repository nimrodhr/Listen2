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
    rag_answer: str = "gpt-4o-mini"
    embedding: str = "text-embedding-3-small"


class AudioConfig(BaseModel):
    mic_device_id: Optional[int] = None
    system_device_id: Optional[int] = None
    sample_rate: int = 24000
    chunk_duration_ms: int = 100


class TranscriptionConfig(BaseModel):
    language: str = "en"
    vad_threshold: float = 0.5
    vad_prefix_padding_ms: int = 300
    vad_silence_duration_ms: int = 500
    noise_reduction: str = "near_field"


class KnowledgeBaseConfig(BaseModel):
    directory: str = ""
    chunk_size: int = 500
    chunk_overlap: int = 50
    chromadb_path: str = str(LISTEN_DIR / "chromadb")


class QuestionDetectionConfig(BaseModel):
    confidence_threshold: float = 0.7
    context_window_turns: int = 10
    context_window_seconds: int = 60


class RagConfig(BaseModel):
    top_k: int = 5
    max_answer_length: int = 200


class ServerConfig(BaseModel):
    ws_port: int = 8765
    ws_host: str = "127.0.0.1"


class Settings(BaseModel):
    version: int = 1
    api_keys: ApiKeysConfig = Field(default_factory=ApiKeysConfig)
    models: ModelsConfig = Field(default_factory=ModelsConfig)
    audio: AudioConfig = Field(default_factory=AudioConfig)
    transcription: TranscriptionConfig = Field(default_factory=TranscriptionConfig)
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
