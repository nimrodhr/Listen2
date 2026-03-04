"""Tests for the transcript store."""

import asyncio
import pytest

from listen.transcription.transcript_store import TranscriptStore


@pytest.mark.asyncio
class TestTranscriptStore:
    async def test_add_delta_creates_entry(self):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Hello", "me")
        entries = store.get_recent(10)
        assert len(entries) == 1
        assert entries[0].text == "Hello"
        assert entries[0].speaker == "me"
        assert entries[0].is_final is False

    async def test_add_delta_appends_text(self):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Hello", "me")
        await store.add_delta("turn-1", " world", "me")
        entries = store.get_recent(10)
        assert len(entries) == 1
        assert entries[0].text == "Hello world"

    async def test_finalize_turn(self):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Helo", "me")
        await store.finalize_turn("turn-1", "Hello", "me")
        entries = store.get_recent(10)
        assert entries[0].text == "Hello"
        assert entries[0].is_final is True

    async def test_multiple_speakers(self):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Hi there", "me")
        await store.finalize_turn("turn-1", "Hi there", "me")
        await store.add_delta("turn-2", "Hey!", "them")
        await store.finalize_turn("turn-2", "Hey!", "them")

        me_entries = store.get_recent_by_speaker("me")
        them_entries = store.get_recent_by_speaker("them")
        assert len(me_entries) == 1
        assert len(them_entries) == 1

    async def test_clear(self):
        store = TranscriptStore()
        await store.add_delta("turn-1", "Hello", "me")
        store.clear()
        assert store.count == 0
        assert store.get_recent() == []

    async def test_get_recent_limits(self):
        store = TranscriptStore()
        for i in range(20):
            await store.add_delta(f"turn-{i}", f"msg {i}", "me")
        recent = store.get_recent(5)
        assert len(recent) == 5
        assert recent[-1].text == "msg 19"

    async def test_callback_on_delta(self):
        store = TranscriptStore()
        received = []

        async def on_delta(entry):
            received.append(entry)

        store.on_delta = on_delta
        await store.add_delta("turn-1", "Hello", "me")
        assert len(received) == 1

    async def test_callback_on_completed(self):
        store = TranscriptStore()
        received = []

        async def on_completed(entry):
            received.append(entry)

        store.on_completed = on_completed
        await store.finalize_turn("turn-1", "Hello", "me")
        assert len(received) == 1
        assert received[0].is_final is True
