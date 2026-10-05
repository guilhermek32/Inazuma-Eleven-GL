"""One-line JSON logs on stdout, shaped like the match runtime's:
{"ts", "svc", "level", "event", ...fields}."""

from __future__ import annotations

import json
import logging
import sys
import time

_logger = logging.getLogger("svc")


class _JsonFormatter(logging.Formatter):
    def __init__(self, service: str):
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        line = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)), "svc": self.service,
                "level": record.levelname.lower(), "event": record.getMessage()}
        line.update(getattr(record, "fields", {}))
        if record.exc_info:
            line["exc"] = self.formatException(record.exc_info)
        return json.dumps(line, default=str)


def setup(service: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(_JsonFormatter(service))
    _logger.handlers[:] = [handler]
    _logger.setLevel(logging.INFO)
    _logger.propagate = False


def log_event(event: str, level: int = logging.INFO, exc_info: bool = False, **fields) -> None:
    _logger.log(level, event, extra={"fields": fields}, exc_info=exc_info)
