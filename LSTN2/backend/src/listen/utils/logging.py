"""Structured JSON logging for Listen backend."""

import json
import logging
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path


LOG_DIR = Path.home() / ".listen" / "logs"
LOG_FILE = LOG_DIR / "backend.log"
MAX_LOG_SIZE = 5 * 1024 * 1024  # 5 MB
BACKUP_COUNT = 3


class JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "ts": record.created,
            "level": record.levelname,
            "module": record.module,
            "msg": record.getMessage(),
        }
        if hasattr(record, "extra") and record.extra:
            log_entry["extra"] = record.extra
        if record.exc_info and record.exc_info[1]:
            log_entry["error"] = str(record.exc_info[1])
        return json.dumps(log_entry)


def setup_logging(level: int = logging.INFO) -> None:
    """Configure structured JSON logging to stdout and rotating log file."""
    formatter = JSONFormatter()

    # Stdout handler
    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setFormatter(formatter)

    # Rotating file handler
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    file_handler = RotatingFileHandler(
        LOG_FILE,
        maxBytes=MAX_LOG_SIZE,
        backupCount=BACKUP_COUNT,
    )
    file_handler.setFormatter(formatter)

    root = logging.getLogger("listen")
    root.setLevel(level)
    root.addHandler(stdout_handler)
    root.addHandler(file_handler)
    root.propagate = False
