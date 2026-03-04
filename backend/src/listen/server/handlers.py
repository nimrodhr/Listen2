"""Route incoming WebSocket commands to appropriate modules."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any, Callable, Coroutine

if TYPE_CHECKING:
    from listen.server.ws_server import ListenWSServer

logger = logging.getLogger("listen.server.handlers")

# Type alias for handler functions
Handler = Callable[["ListenWSServer", dict], Coroutine[Any, Any, None]]


async def handle_start_recording(server: "ListenWSServer", msg: dict) -> None:
    """Start audio capture and transcription."""
    mic_device_id = msg.get("mic_device_id")
    system_device_id = msg.get("system_device_id")
    logger.info(
        "Start recording requested",
        extra={"mic_device_id": mic_device_id, "system_device_id": system_device_id},
    )
    await server.start_recording(mic_device_id, system_device_id)


async def handle_stop_recording(server: "ListenWSServer", msg: dict) -> None:
    """Stop audio capture and transcription."""
    logger.info("Stop recording requested")
    await server.stop_recording()


async def handle_update_settings(server: "ListenWSServer", msg: dict) -> None:
    """Update application settings."""
    settings_data = msg.get("settings", {})
    logger.info("Settings update requested")
    await server.update_settings(settings_data)


async def handle_get_audio_devices(server: "ListenWSServer", msg: dict) -> None:
    """Return list of available audio devices."""
    logger.info("Audio devices list requested")
    await server.send_audio_devices()


async def handle_check_audio_setup(server: "ListenWSServer", msg: dict) -> None:
    """Check BlackHole audio setup status."""
    logger.info("Audio setup check requested")
    await server.check_audio_setup()


async def handle_ingest_kb(server: "ListenWSServer", msg: dict) -> None:
    """Ingest knowledge base documents from a directory or file list."""
    directory = msg.get("directory", "")
    files = msg.get("files")
    # Accept single file_path from frontend as well
    file_path = msg.get("file_path")
    if file_path and not files:
        files = [file_path]
    logger.info("KB ingestion requested", extra={"directory": directory, "files": files})
    await server.ingest_kb(directory=directory, files=files)


async def handle_remove_kb_source(server: "ListenWSServer", msg: dict) -> None:
    """Remove a source from the knowledge base."""
    source_path = msg.get("source_path") or msg.get("source_id", "")
    logger.info("KB source removal requested", extra={"source_path": source_path})
    await server.remove_kb_source(source_path)


async def handle_get_kb_status(server: "ListenWSServer", msg: dict) -> None:
    """Get knowledge base status."""
    logger.info("KB status requested")
    await server.send_kb_status()


async def handle_ping(server: "ListenWSServer", msg: dict) -> None:
    """Respond to ping from frontend."""
    import time
    from listen.server.protocol import PongEvent
    await server.send(PongEvent(server_time=time.time()))


async def handle_get_transcript_sessions(server: "ListenWSServer", msg: dict) -> None:
    """List saved transcript sessions."""
    from listen.server.protocol import TranscriptSessionsEvent
    sessions = server._transcript_persistence.list_sessions()
    await server.send(TranscriptSessionsEvent(sessions=sessions))


async def handle_get_transcript_session(server: "ListenWSServer", msg: dict) -> None:
    """Load a specific transcript session."""
    from listen.server.protocol import TranscriptSessionDataEvent
    session_id = msg.get("session_id", "")
    data = server._transcript_persistence.load_session(session_id)
    if data:
        await server.send(TranscriptSessionDataEvent(
            session_id=session_id,
            entries=data.get("entries", []),
            started_at=data.get("started_at", 0),
        ))


async def handle_query_kb(server: "ListenWSServer", msg: dict) -> None:
    """Query the knowledge base vector store and return matching chunks."""
    query = msg.get("query", "")
    n_results = msg.get("n_results", 5)
    if not isinstance(n_results, int) or n_results < 1:
        n_results = 5
    logger.info("KB query requested", extra={"query": query, "n_results": n_results})
    await server.query_kb(query, n_results)


async def handle_flush_kb(server: "ListenWSServer", msg: dict) -> None:
    """Flush all documents from the knowledge base."""
    logger.info("KB flush requested")
    await server.flush_kb()


async def handle_get_activity_log(server: "ListenWSServer", msg: dict) -> None:
    """Return recent activity log entries."""
    from dataclasses import asdict
    from listen.server.protocol import ActivityLogEvent
    entries = server._activity_log.get_recent()
    await server.send(ActivityLogEvent(entries=[asdict(e) for e in entries]))


COMMAND_HANDLERS: dict[str, Handler] = {
    "command.start_recording": handle_start_recording,
    "command.stop_recording": handle_stop_recording,
    "command.update_settings": handle_update_settings,
    "command.get_audio_devices": handle_get_audio_devices,
    "command.check_audio_setup": handle_check_audio_setup,
    "command.ingest_kb": handle_ingest_kb,
    "command.remove_kb_source": handle_remove_kb_source,
    "command.get_kb_status": handle_get_kb_status,
    "command.ping": handle_ping,
    "command.get_transcript_sessions": handle_get_transcript_sessions,
    "command.get_transcript_session": handle_get_transcript_session,
    "command.get_activity_log": handle_get_activity_log,
    "command.query_kb": handle_query_kb,
    "command.flush_kb": handle_flush_kb,
}
