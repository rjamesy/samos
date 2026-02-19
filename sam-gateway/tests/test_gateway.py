"""Tests for sam-gateway endpoints (Responses API)."""
import os
import pytest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


# Patch env vars before importing app
os.environ.setdefault("OPENAI_API_KEY", "test-key")
os.environ.setdefault("SAM_MODEL", "gpt-5.2")

from app.main import app  # noqa: E402
from app.sessions import SessionStore  # noqa: E402


client = TestClient(app)


# ---------- Health ----------

class TestHealth:
    def test_health_returns_ok(self):
        resp = client.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["service"] == "sam-gateway"
        assert "version" in data
        assert "uptime_s" in data

    def test_health_has_session_count(self):
        resp = client.get("/health")
        data = resp.json()
        assert "active_sessions" in data


# ---------- Message validation ----------

class TestMessageValidation:
    def test_empty_text_returns_400(self):
        resp = client.post("/v1/sam/message", json={"text": ""})
        assert resp.status_code == 400
        assert "empty text" in resp.json()["error"]

    def test_whitespace_only_returns_400(self):
        resp = client.post("/v1/sam/message", json={"text": "   "})
        assert resp.status_code == 400

    def test_missing_text_returns_400(self):
        resp = client.post("/v1/sam/message", json={})
        assert resp.status_code == 400

    def test_invalid_json_returns_400(self):
        resp = client.post(
            "/v1/sam/message",
            data="{not-json",
            headers={"content-type": "application/json"},
        )
        assert resp.status_code == 400
        assert "invalid json body" in resp.json()["error"]

    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_stale_session_creates_new(self, mock_send):
        mock_send.return_value = ("Fresh start!", "resp_fresh", "gpt-5.2-2025-12-11", {"total_tokens": 10})

        resp = client.post("/v1/sam/message", json={
            "session_id": "sam_nonexistent",
            "text": "Hello",
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["session_id"] != "sam_nonexistent"
        assert data["session_id"].startswith("sam_")
        assert data["trace"]["new_session"] is True


# ---------- Message happy path ----------

class TestMessageHappyPath:
    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_new_session_created(self, mock_send):
        mock_send.return_value = (
            "Hey Richard! What's up?",
            "resp_abc123",
            "gpt-5.2-2025-12-11",
            {"total_tokens": 42},
        )

        resp = client.post("/v1/sam/message", json={"text": "Hello"})
        assert resp.status_code == 200
        data = resp.json()

        assert data["session_id"].startswith("sam_")
        assert data["reply_text"] == "Hey Richard! What's up?"
        assert data["latency_ms"] >= 0
        assert data["model"] == "gpt-5.2-2025-12-11"
        assert data["trace"]["new_session"] is True
        assert data["trace"]["response_id"] == "resp_abc123"
        assert data["trace"]["model"] == "gpt-5.2-2025-12-11"

    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_existing_session_reused(self, mock_send):
        mock_send.return_value = (
            "First reply",
            "resp_first",
            "gpt-5.2-2025-12-11",
            {"total_tokens": 10},
        )

        # Create session
        resp1 = client.post("/v1/sam/message", json={"text": "Hello"})
        session_id = resp1.json()["session_id"]

        # Reuse session — mock should be called with previous_response_id
        mock_send.return_value = (
            "Second reply",
            "resp_second",
            "gpt-5.2-2025-12-11",
            {"total_tokens": 20},
        )
        resp2 = client.post("/v1/sam/message", json={
            "session_id": session_id,
            "text": "What can you do?",
        })
        assert resp2.status_code == 200
        data = resp2.json()
        assert data["session_id"] == session_id
        assert data["reply_text"] == "Second reply"
        assert data["trace"]["new_session"] is False

        # Verify previous_response_id was passed
        call_args = mock_send.call_args
        assert call_args.kwargs.get("previous_response_id") == "resp_first" or \
               (len(call_args.args) > 1 and call_args.args[1] == "resp_first") or \
               call_args[1].get("previous_response_id") == "resp_first"

    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_metadata_passed_through(self, mock_send):
        mock_send.return_value = ("Sure!", "resp_meta", "gpt-5.2-2025-12-11", {"total_tokens": 5})

        resp = client.post("/v1/sam/message", json={
            "text": "Hi",
            "metadata": {"source": "stt", "confidence": 0.95, "device": "macOS"},
        })
        assert resp.status_code == 200

    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_trace_includes_usage(self, mock_send):
        mock_send.return_value = (
            "Reply",
            "resp_usage",
            "gpt-5.2-2025-12-11",
            {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
        )

        resp = client.post("/v1/sam/message", json={"text": "Hello"})
        data = resp.json()
        assert data["trace"]["usage"]["total_tokens"] == 15

    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_response_includes_model(self, mock_send):
        mock_send.return_value = ("Hi!", "resp_model", "gpt-5.2-2025-12-11", {"total_tokens": 5})

        resp = client.post("/v1/sam/message", json={"text": "Hello"})
        data = resp.json()
        assert data["model"] == "gpt-5.2-2025-12-11"
        assert data["trace"]["model"] == "gpt-5.2-2025-12-11"


# ---------- Agent errors ----------

class TestAgentErrors:
    @patch("app.main.send_message", new_callable=AsyncMock)
    def test_agent_error_returns_502(self, mock_send):
        mock_send.side_effect = RuntimeError("Agent run failed")

        resp = client.post("/v1/sam/message", json={"text": "Hello"})
        assert resp.status_code == 502
        assert "agent error" in resp.json()["error"]


# ---------- Session store ----------

class TestSessionStore:
    def test_create_and_get(self):
        store = SessionStore()
        sid = store.create("resp_xyz")
        assert sid.startswith("sam_")
        assert store.get_response_id(sid) == "resp_xyz"

    def test_get_nonexistent_returns_none(self):
        store = SessionStore()
        assert store.get_response_id("sam_nope") is None

    def test_update_changes_response_id(self):
        store = SessionStore()
        sid = store.create("resp_first")
        assert store.get_response_id(sid) == "resp_first"
        store.update(sid, "resp_second")
        assert store.get_response_id(sid) == "resp_second"

    def test_update_increments_turn_count(self):
        store = SessionStore()
        sid = store.create("resp_tc")
        store.update(sid, "resp_tc2")
        store.update(sid, "resp_tc3")
        sessions = store.all_sessions()
        assert sessions[sid]["turn_count"] == 3  # 1 from create + 2 updates

    def test_count(self):
        store = SessionStore()
        assert store.count() == 0
        store.create("r1")
        store.create("r2")
        assert store.count() == 2
