"""Tests for transcript persistence."""

import json
import pytest

from listen.transcription.transcript_store import TranscriptStore
from listen.transcription.transcript_persistence import TranscriptPersistence


@pytest.mark.asyncio
class TestTranscriptPersistence:
    async def test_save_and_load_session(self, tmp_path):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Hello there", "me")
        await store.finalize_turn("turn-1", "Hello there", "me")
        await store.add_delta("turn-2", "Hi!", "them")
        await store.finalize_turn("turn-2", "Hi!", "them")

        persistence = TranscriptPersistence(transcripts_dir=str(tmp_path))
        session_id = persistence.start_session()
        path = await persistence.end_session(store)

        assert path is not None
        assert path.exists()

        loaded = persistence.load_session(session_id)
        assert loaded is not None
        assert len(loaded["entries"]) == 2
        assert loaded["entries"][0]["speaker"] == "me"
        assert loaded["entries"][1]["speaker"] == "them"

    async def test_list_sessions(self, tmp_path):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Test", "me")
        await store.finalize_turn("turn-1", "Test", "me")

        persistence = TranscriptPersistence(transcripts_dir=str(tmp_path))
        persistence.start_session()
        await persistence.end_session(store)

        sessions = persistence.list_sessions()
        assert len(sessions) == 1
        assert sessions[0]["entry_count"] == 1

    async def test_delete_session(self, tmp_path):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Test", "me")
        await store.finalize_turn("turn-1", "Test", "me")

        persistence = TranscriptPersistence(transcripts_dir=str(tmp_path))
        session_id = persistence.start_session()
        await persistence.end_session(store)

        assert persistence.delete_session(session_id) is True
        assert persistence.load_session(session_id) is None

    async def test_empty_session_not_saved(self, tmp_path):
        store = TranscriptStore()
        persistence = TranscriptPersistence(transcripts_dir=str(tmp_path))
        persistence.start_session()
        path = await persistence.end_session(store)
        assert path is None
