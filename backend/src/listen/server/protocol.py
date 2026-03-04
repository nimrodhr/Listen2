"""WebSocket message protocol definitions.

All messages are JSON objects with a required 'type' field.
Frontend → Backend messages use 'command.*' prefix.
Backend → Frontend messages use 'event.*' prefix.
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Optional
import json


# --- Frontend → Backend Commands ---


@dataclass
class StartRecordingCommand:
    type: str = "command.start_recording"
    mic_device_id: Optional[int] = None
    system_device_id: Optional[int] = None


@dataclass
class StopRecordingCommand:
    type: str = "command.stop_recording"


@dataclass
class UpdateSettingsCommand:
    type: str = "command.update_settings"
    settings: dict = field(default_factory=dict)


@dataclass
class GetAudioDevicesCommand:
    type: str = "command.get_audio_devices"


@dataclass
class CheckAudioSetupCommand:
    type: str = "command.check_audio_setup"


@dataclass
class IngestKBCommand:
    type: str = "command.ingest_kb"
    directory: str = ""


@dataclass
class RemoveKBSourceCommand:
    type: str = "command.remove_kb_source"
    source_path: str = ""


@dataclass
class GetKBStatusCommand:
    type: str = "command.get_kb_status"


@dataclass
class QueryKBCommand:
    query: str = ""
    n_results: int = 5
    type: str = "command.query_kb"


@dataclass
class PingCommand:
    type: str = "command.ping"


@dataclass
class GetActivityLogCommand:
    type: str = "command.get_activity_log"


# --- Backend → Frontend Events ---


@dataclass
class ConnectedEvent:
    type: str = "event.connected"
    version: str = "0.1.0"


@dataclass
class PongEvent:
    type: str = "event.pong"
    server_time: float = 0.0


@dataclass
class TranscriptDeltaEvent:
    turn_id: str
    speaker: str
    delta_text: str
    timestamp: float
    type: str = "event.transcript.delta"


@dataclass
class TranscriptCompletedEvent:
    turn_id: str
    speaker: str
    final_text: str
    timestamp: float
    type: str = "event.transcript.completed"


@dataclass
class QuestionDetectedEvent:
    question_id: str
    question_text: str
    source_turn_id: str
    confidence: float
    category: str
    timestamp: float
    type: str = "event.question.detected"


@dataclass
class SourceReference:
    file_name: str
    file_path: str
    page: Optional[int] = None
    chunk_preview: str = ""


@dataclass
class QuestionAnsweredEvent:
    question_id: str
    answer_text: str
    sources: list[dict] = field(default_factory=list)
    type: str = "event.question.answered"


@dataclass
class QuestionNoAnswerEvent:
    question_id: str
    reason: str
    type: str = "event.question.no_answer"


@dataclass
class AudioDevicesEvent:
    input_devices: list[dict] = field(default_factory=list)
    output_devices: list[dict] = field(default_factory=list)
    type: str = "event.audio_devices"


@dataclass
class AudioSetupStatusEvent:
    blackhole_installed: bool = False
    multi_output_configured: bool = False
    blackhole_device_id: Optional[int] = None
    instructions: Optional[list[str]] = None
    type: str = "event.audio_setup_status"


@dataclass
class KBIngestionProgressEvent:
    file: str
    status: str  # "processing" | "completed" | "failed"
    progress: float
    total_files: int
    completed_files: int
    type: str = "event.kb.ingestion_progress"


@dataclass
class KBStatusEvent:
    total_documents: int = 0
    total_chunks: int = 0
    sources: list[dict] = field(default_factory=list)
    index_health: str = "unknown"
    embedding_model: str = ""
    vector_db_type: str = ""
    type: str = "event.kb.status"


@dataclass
class KBQueryResultsEvent:
    query: str = ""
    results: list[dict] = field(default_factory=list)
    total_results: int = 0
    type: str = "event.kb.query_results"


@dataclass
class RecordingStateEvent:
    is_recording: bool = False
    mic_active: bool = False
    system_audio_active: bool = False
    openai_mic_connected: bool = False
    openai_system_connected: bool = False
    type: str = "event.recording_state"


@dataclass
class ErrorEvent:
    error_code: str
    message: str
    component: str  # "audio" | "transcription" | "question_detection" | "rag" | "kb" | "server"
    recoverable: bool = True
    details: Optional[dict] = None
    type: str = "event.error"


@dataclass
class SettingsUpdatedEvent:
    settings: dict = field(default_factory=dict)
    type: str = "event.settings_updated"


@dataclass
class TranscriptSessionsEvent:
    sessions: list[dict] = field(default_factory=list)
    type: str = "event.transcript.sessions"


@dataclass
class TranscriptSessionDataEvent:
    session_id: str = ""
    entries: list[dict] = field(default_factory=list)
    started_at: float = 0.0
    type: str = "event.transcript.session_data"


@dataclass
class ActivityLogEvent:
    entries: list[dict] = field(default_factory=list)
    type: str = "event.activity_log"


@dataclass
class ActivityLogEntryEvent:
    entry: dict = field(default_factory=dict)
    type: str = "event.activity_log.entry"


def serialize(event: Any) -> str:
    """Serialize a protocol event to JSON string."""
    return json.dumps(asdict(event))


def parse_command(raw: str) -> dict:
    """Parse an incoming JSON message from the frontend."""
    return json.loads(raw)
