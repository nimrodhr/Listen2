"""Listen backend entry point."""

import asyncio
import atexit
import logging
import os
import signal
import sys
from pathlib import Path

from listen.config import load_settings
from listen.utils.logging import setup_logging

logger = logging.getLogger("listen.main")

PID_FILE = Path.home() / ".listen" / "backend.pid"


def _handle_unhandled_exception(exc_type, exc_value, exc_tb):
    """Log unhandled exceptions instead of letting them silently crash."""
    if issubclass(exc_type, KeyboardInterrupt):
        sys.__excepthook__(exc_type, exc_value, exc_tb)
        return
    logger.critical("Unhandled exception", exc_info=(exc_type, exc_value, exc_tb))


def _handle_asyncio_exception(loop, context):
    """Log unhandled asyncio exceptions."""
    exception = context.get("exception")
    message = context.get("message", "Unhandled asyncio exception")
    if exception:
        logger.error(f"Asyncio error: {message}", exc_info=exception)
    else:
        logger.error(f"Asyncio error: {message}")


def _kill_stale_instance() -> None:
    """Kill any stale backend from a previous run using the PID file."""
    if not PID_FILE.exists():
        return
    try:
        old_pid = int(PID_FILE.read_text().strip())
        # Check if the process is still alive
        os.kill(old_pid, 0)
        logger.warning(f"Killing stale backend (pid={old_pid})")
        os.kill(old_pid, signal.SIGTERM)
        # Wait briefly for it to exit
        import time
        for _ in range(10):
            time.sleep(0.2)
            try:
                os.kill(old_pid, 0)
            except OSError:
                break
        else:
            # Still alive — force kill
            logger.warning(f"Force-killing stale backend (pid={old_pid})")
            os.kill(old_pid, signal.SIGKILL)
    except (ValueError, OSError):
        pass  # PID file invalid or process already gone
    finally:
        PID_FILE.unlink(missing_ok=True)


def _write_pid_file() -> None:
    """Write our PID to the PID file."""
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))


def _remove_pid_file() -> None:
    """Remove the PID file on exit."""
    PID_FILE.unlink(missing_ok=True)


async def main() -> None:
    setup_logging()

    # Install global exception handlers
    sys.excepthook = _handle_unhandled_exception
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(_handle_asyncio_exception)

    # Single-instance guard: kill any stale backend, then claim the PID file
    _kill_stale_instance()
    _write_pid_file()
    atexit.register(_remove_pid_file)

    settings = load_settings()

    logger.info("Listen backend starting", extra={"port": settings.server.ws_port})

    # Import here to avoid circular imports and slow startup
    from listen.server.ws_server import ListenWSServer

    server = ListenWSServer(settings)

    try:
        await server.start()
    except KeyboardInterrupt:
        logger.info("Shutdown requested (KeyboardInterrupt)")
    except Exception:
        logger.critical("Fatal error in server", exc_info=True)
        raise
    finally:
        logger.info("Listen backend shutting down")
        _remove_pid_file()


if __name__ == "__main__":
    asyncio.run(main())
