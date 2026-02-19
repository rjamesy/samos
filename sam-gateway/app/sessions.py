"""In-memory session store — maps session_id to last response_id for conversation chaining."""
import threading
import time
import uuid


class SessionStore:
    def __init__(self):
        self._sessions: dict[str, dict] = {}
        self._lock = threading.Lock()

    def create(self, response_id: str) -> str:
        session_id = f"sam_{uuid.uuid4().hex[:12]}"
        with self._lock:
            self._sessions[session_id] = {
                "last_response_id": response_id,
                "created_at": time.time(),
                "last_activity": time.time(),
                "turn_count": 1,
            }
        return session_id

    def get_response_id(self, session_id: str) -> str | None:
        with self._lock:
            entry = self._sessions.get(session_id)
            return entry["last_response_id"] if entry else None

    def update(self, session_id: str, response_id: str):
        with self._lock:
            entry = self._sessions.get(session_id)
            if entry:
                entry["last_response_id"] = response_id
                entry["last_activity"] = time.time()
                entry["turn_count"] += 1

    def count(self) -> int:
        with self._lock:
            return len(self._sessions)

    def all_sessions(self) -> dict[str, dict]:
        with self._lock:
            return dict(self._sessions)
