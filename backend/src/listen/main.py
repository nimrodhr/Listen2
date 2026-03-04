"""Listen backend entry point."""

import asyncio
import logging
import sys

from listen.config import load_settings
from listen.utils.logging import setup_logging

logger = logging.getLogger("listen.main")


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


async def main() -> None:
    setup_logging()

    # Install global exception handlers
    sys.excepthook = _handle_unhandled_exception
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(_handle_asyncio_exception)

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


if __name__ == "__main__":
    asyncio.run(main())
