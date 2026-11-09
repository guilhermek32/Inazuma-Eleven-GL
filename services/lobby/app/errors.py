"""Errors the lobby reports to clients as {"error": code, "detail": text}."""


class LobbyError(Exception):
    status = 400

    def __init__(self, error: str, detail: str):
        super().__init__(detail)
        self.error = error
        self.detail = detail


class NotFound(LobbyError):
    status = 404


class Conflict(LobbyError):
    status = 409


class Unavailable(LobbyError):
    status = 503
