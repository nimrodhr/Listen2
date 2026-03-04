"""Tests for the WebSocket protocol serialization."""

import json

from listen.server.protocol import (
    ConnectedEvent,
    ErrorEvent,
    RecordingStateEvent,
    TranscriptDeltaEvent,
    serialize,
    parse_command,
)


class TestProtocol:
    def test_serialize_connected_event(self):
        event = ConnectedEvent()
        raw = serialize(event)
        data = json.loads(raw)
        assert data["type"] == "event.connected"
        assert data["version"] == "0.1.0"

    def test_serialize_error_event(self):
        event = ErrorEvent(
            error_code="TEST_ERROR",
            message="Something went wrong",
            component="test",
            recoverable=True,
        )
        raw = serialize(event)
        data = json.loads(raw)
        assert data["error_code"] == "TEST_ERROR"
        assert data["recoverable"] is True

    def test_serialize_transcript_delta(self):
        event = TranscriptDeltaEvent(
            turn_id="turn-123",
            speaker="me",
            delta_text="Hello world",
            timestamp=1234567890.123,
        )
        raw = serialize(event)
        data = json.loads(raw)
        assert data["type"] == "event.transcript.delta"
        assert data["turn_id"] == "turn-123"
        assert data["speaker"] == "me"

    def test_serialize_recording_state(self):
        event = RecordingStateEvent(
            is_recording=True,
            mic_active=True,
            system_audio_active=True,
        )
        raw = serialize(event)
        data = json.loads(raw)
        assert data["is_recording"] is True
        assert data["openai_mic_connected"] is False  # default

    def test_parse_command(self):
        raw = json.dumps({"type": "command.start_recording", "mic_device_id": 3})
        msg = parse_command(raw)
        assert msg["type"] == "command.start_recording"
        assert msg["mic_device_id"] == 3

    def test_parse_invalid_json(self):
        import pytest
        with pytest.raises(json.JSONDecodeError):
            parse_command("not valid json")
