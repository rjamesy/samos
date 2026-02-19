"""Sam Gateway — FastAPI service proxying to OpenAI Responses API (gpt-5.2)."""
import logging
import os
import time
import uuid

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .openai_client import send_message
from .sessions import SessionStore

# ---------- Logging ----------

LOG_JSON = os.environ.get("LOG_JSON", "true").lower() == "true"

if LOG_JSON:
    logging.basicConfig(
        level=logging.INFO,
        format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
    )
else:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

logger = logging.getLogger("sam-gateway")

# ---------- App ----------

VERSION = "0.2.0"

app = FastAPI(title="Sam Gateway", version=VERSION)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

sessions = SessionStore()
_started_at = time.time()


# ---------- Health ----------

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "service": "sam-gateway",
        "version": VERSION,
        "uptime_s": int(time.time() - _started_at),
        "active_sessions": sessions.count(),
    }


# ---------- Message ----------

@app.post("/v1/sam/message")
async def message(request: Request):
    """Send a message to Sam.

    Request:  { "session_id": str|null, "text": str, "metadata": object|null }
    Response: { "session_id": str, "reply_text": str, "latency_ms": int, "model": str, "trace": object }
    """
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "invalid json body"}, status_code=400)

    if not isinstance(body, dict):
        return JSONResponse({"error": "json body must be an object"}, status_code=400)

    text = (body.get("text") or "").strip()
    session_id = body.get("session_id")
    metadata = body.get("metadata")

    request_id = uuid.uuid4().hex[:8]

    if not text:
        return JSONResponse({"error": "empty text", "request_id": request_id}, status_code=400)

    t0 = time.monotonic()

    # --- Resolve previous_response_id for conversation continuity ---
    previous_response_id: str | None = None
    new_session = False

    if session_id:
        previous_response_id = sessions.get_response_id(session_id)
        if previous_response_id is None:
            # Stale session (gateway restarted) — start fresh instead of 404
            logger.info("stale_session | req=%s | session=%s | starting fresh", request_id, session_id)
            session_id = None

    # --- Send to OpenAI Responses API ---
    try:
        reply_text, response_id, model_name, usage = await send_message(
            text=text,
            previous_response_id=previous_response_id,
        )
    except Exception as e:
        logger.error(
            "agent_error | req=%s | session=%s | error=%s",
            request_id, session_id or "new", e,
        )
        return JSONResponse(
            {"error": f"agent error: {e}", "session_id": session_id, "request_id": request_id},
            status_code=502,
        )

    total_ms = int((time.monotonic() - t0) * 1000)

    # --- Update or create session ---
    if session_id:
        sessions.update(session_id, response_id)
    else:
        session_id = sessions.create(response_id)
        new_session = True

    logger.info(
        "message | req=%s | session=%s | model=%s | new=%s | text=%r | reply_len=%d | "
        "total_ms=%d | tokens=%s | source=%s",
        request_id, session_id, model_name, new_session,
        text[:60], len(reply_text),
        total_ms, usage,
        (metadata or {}).get("source", "unknown"),
    )

    return {
        "session_id": session_id,
        "reply_text": reply_text,
        "latency_ms": total_ms,
        "model": model_name,
        "trace": {
            "request_id": request_id,
            "response_id": response_id,
            "new_session": new_session,
            "model": model_name,
            "usage": usage,
        },
    }
