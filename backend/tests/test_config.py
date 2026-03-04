"""Tests for configuration loading and saving."""

import json
import os
from pathlib import Path

import pytest

from listen.config import Settings, load_settings, save_settings, SETTINGS_FILE


class TestSettings:
    def test_default_settings(self):
        """Default settings should have sensible values."""
        s = Settings()
        assert s.version == 1
        assert s.server.ws_port == 8765
        assert s.server.ws_host == "127.0.0.1"
        assert s.models.transcription == "gpt-4o-transcribe"
        assert s.audio.sample_rate == 24000

    def test_settings_from_dict(self, sample_settings_data):
        """Settings should be constructable from a dict."""
        s = Settings.model_validate(sample_settings_data)
        assert s.api_keys.openai == "sk-test-key"
        assert s.models.question_detection == "gpt-4o-mini"

    def test_settings_roundtrip(self, tmp_path, monkeypatch):
        """Settings should survive a save/load roundtrip."""
        settings_file = tmp_path / "settings.json"
        listen_dir = tmp_path

        monkeypatch.setattr("listen.config.SETTINGS_FILE", settings_file)
        monkeypatch.setattr("listen.config.LISTEN_DIR", listen_dir)

        original = Settings()
        original.api_keys.openai = "test-key-123"
        original.audio.mic_device_id = 5

        save_settings(original)
        assert settings_file.exists()

        loaded = load_settings()
        assert loaded.api_keys.openai == "test-key-123"
        assert loaded.audio.mic_device_id == 5

    def test_settings_file_permissions(self, tmp_path, monkeypatch):
        """Settings file should have restricted permissions."""
        settings_file = tmp_path / "settings.json"
        listen_dir = tmp_path

        monkeypatch.setattr("listen.config.SETTINGS_FILE", settings_file)
        monkeypatch.setattr("listen.config.LISTEN_DIR", listen_dir)

        save_settings(Settings())
        mode = oct(os.stat(settings_file).st_mode)[-3:]
        assert mode == "600"
