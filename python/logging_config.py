"""Shared logging setup: timestamped file + console output for each script run."""

import logging
import sys
from datetime import datetime
from pathlib import Path


def setup_logging(script_name: str, log_dir: str = "logs") -> logging.Logger:
    """Configure root logger with a console handler and a per-run timestamped log file.

    All module-level loggers (logging.getLogger(__name__)) inherit these handlers
    automatically, so every module's output appears in both the console and the log file.

    Returns the logger for the calling script.
    """
    Path(log_dir).mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = Path(log_dir) / f"{script_name}_{timestamp}.log"

    formatter = logging.Formatter(
        "%(asctime)s | %(levelname)-8s | %(name)-40s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.addHandler(file_handler)
    root.addHandler(console_handler)

    # Keep third-party HTTP library chatter out of the logs
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("requests").setLevel(logging.WARNING)

    logger = logging.getLogger(script_name)
    logger.info("Log file: %s", log_path.resolve())
    return logger
