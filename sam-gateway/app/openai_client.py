"""OpenAI Responses API wrapper — stateless calls with conversation chaining."""
import logging
import os
import time

from openai import AsyncOpenAI

logger = logging.getLogger("sam-gateway.openai")

_client: AsyncOpenAI | None = None

SAM_PROMPT_ID = os.environ.get(
    "SAM_PROMPT_ID",
    "pmpt_699257b571dc81968694d0df12d3bb6c0aa28ce2bb01f314",
)


def get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        _client = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])
    return _client


def get_model() -> str:
    return os.environ.get("SAM_MODEL", "gpt-5.2")


async def send_message(
    text: str,
    previous_response_id: str | None = None,
) -> tuple[str, str, str, dict]:
    """Send user text to Sam via the Responses API.

    Returns (reply_text, response_id, model_name, usage_dict).
    """
    client = get_client()
    model = get_model()

    t0 = time.monotonic()
    response = await client.responses.create(
        model=model,
        prompt={"id": SAM_PROMPT_ID},
        input=text,
        **({"previous_response_id": previous_response_id} if previous_response_id else {}),
    )
    call_ms = int((time.monotonic() - t0) * 1000)

    reply_text = response.output_text or ""
    response_id = response.id
    model_name = response.model or model

    usage = {}
    if response.usage:
        usage = {
            "input_tokens": response.usage.input_tokens,
            "output_tokens": response.usage.output_tokens,
            "total_tokens": response.usage.input_tokens + response.usage.output_tokens,
        }

    logger.info(
        "agent_response | response_id=%s | model=%s | reply_len=%d | call_ms=%d | tokens=%s",
        response_id, model_name, len(reply_text), call_ms, usage,
    )

    return reply_text, response_id, model_name, usage
