"""Listen backend entry point."""

import asyncio
import atexit
import fcntl
import logging
import os
import secrets
import signal
import sys
from pathlib import Path

from listen.config import load_settings
from listen.utils.logging import setup_logging

logger = logging.getLogger("listen.main")

LISTEN_DIR = Path.home() / ".listen"
PID_FILE = LISTEN_DIR / "backend.pid"
LOCK_FILE = LISTEN_DIR / "backend.lock"
WS_TOKEN_FILE = LISTEN_DIR / "ws_token"

# Keep reference to the lock file descriptor so it stays open (and locked)
_lock_fd = None


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
    """Kill any stale backend from a previous run.

    Uses an advisory file lock to detect whether a previous instance is
    truly running.  If the lock is held, reads the PID file to send SIGTERM.
    """
    LISTEN_DIR.mkdir(parents=True, exist_ok=True)

    # Try to acquire the lock — if we get it, no other instance is running
    try:
        fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Lock acquired — no running instance. Clean up stale PID file.
        os.close(fd)
        PID_FILE.unlink(missing_ok=True)
        WS_TOKEN_FILE.unlink(missing_ok=True)
        return
    except OSError:
        pass  # Lock held — another instance is running

    # Lock is held by another process — read its PID and kill it
    if not PID_FILE.exists():
        return
    try:
        old_pid = int(PID_FILE.read_text().strip())
        os.kill(old_pid, 0)  # Check if alive
        logger.warning(f"Killing stale backend (pid={old_pid})")
        os.kill(old_pid, signal.SIGTERM)
        import time
        for _ in range(10):
            time.sleep(0.2)
            try:
                os.kill(old_pid, 0)
            except OSError:
                break
        else:
            logger.warning(f"Force-killing stale backend (pid={old_pid})")
            os.kill(old_pid, signal.SIGKILL)
    except (ValueError, OSError):
        pass  # PID file invalid or process already gone
    finally:
        PID_FILE.unlink(missing_ok=True)
        WS_TOKEN_FILE.unlink(missing_ok=True)


def _acquire_lock() -> None:
    """Acquire the instance lock and write PID file atomically."""
    global _lock_fd
    LISTEN_DIR.mkdir(parents=True, exist_ok=True)
    _lock_fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(_lock_fd)
        _lock_fd = None
        logger.error("Another backend instance is already running")
        sys.exit(1)
    # Write PID for informational purposes
    PID_FILE.write_text(str(os.getpid()))


def _release_lock() -> None:
    """Release the instance lock and clean up PID file."""
    global _lock_fd
    PID_FILE.unlink(missing_ok=True)
    if _lock_fd is not None:
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_UN)
            os.close(_lock_fd)
        except OSError:
            pass
        _lock_fd = None


def _write_ws_token() -> str:
    """Generate a per-session WebSocket auth token and write it to disk."""
    token = secrets.token_hex(32)
    WS_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    WS_TOKEN_FILE.write_text(token)
    os.chmod(WS_TOKEN_FILE, 0o600)
    logger.info(f"WebSocket auth token written to {WS_TOKEN_FILE}")
    return token


def _remove_ws_token() -> None:
    """Remove the WebSocket token file on exit."""
    WS_TOKEN_FILE.unlink(missing_ok=True)


async def main() -> None:
    setup_logging()

    # Install global exception handlers
    sys.excepthook = _handle_unhandled_exception
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(_handle_asyncio_exception)

    # Single-instance guard: kill any stale backend, then claim the lock + PID
    _kill_stale_instance()
    _acquire_lock()
    atexit.register(_release_lock)

    ws_token = _write_ws_token()
    atexit.register(_remove_ws_token)

    settings = load_settings()

    logger.info("Listen backend starting", extra={"port": settings.server.ws_port})

    # Import here to avoid circular imports and slow startup
    from listen.server.ws_server import ListenWSServer

    server = ListenWSServer(settings, ws_token=ws_token)

    try:
        await server.start()
    except KeyboardInterrupt:
        logger.info("Shutdown requested (KeyboardInterrupt)")
    except Exception:
        logger.critical("Fatal error in server", exc_info=True)
        raise
    finally:
        logger.info("Listen backend shutting down")
        _release_lock()
        _remove_ws_token()


if __name__ == "__main__":
    asyncio.run(main())
