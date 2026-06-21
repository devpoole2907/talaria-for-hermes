"""
Talaria push gateway hook.

Fires on `agent:end` and POSTs a compact, HMAC-signed payload to the Talaria
push Worker, which fans it out to the user's registered devices as an APNs alert.

Install:
    cp -r HermesHook/talaria-push ~/.hermes/hooks/talaria-push

Configure (in the gateway's environment — profile .env or shell):
    TALARIA_PUSH_URL    https://talaria-push.<you>.workers.dev   (required)
    TALARIA_HMAC_SECRET shared secret — must equal the Worker's HMAC_SECRET
    TALARIA_SESSION_KEY (recommended) the push session key shown in the app's
                        Settings. Device tokens are keyed by this value, so it
                        MUST match for pushes to route. If unset, we fall back to
                        the session key / user id from the event context.

On its first call the hook logs the available context keys (once) so you can see
exactly what identifiers Hermes provides and pick the right one.
"""

import hashlib
import hmac
import json
import logging
import os

import httpx

log = logging.getLogger("talaria-push")
_logged_context_once = False


def _resolve_session_key(context: dict) -> str:
    override = os.environ.get("TALARIA_SESSION_KEY", "").strip()
    if override:
        return override
    # Fall back to whatever stable identifier the event carries.
    for field in ("session_key", "user_id", "channel_id"):
        value = str(context.get(field) or "").strip()
        if value:
            return value
    return ""


async def handle(event_type: str, context: dict):
    global _logged_context_once
    if not _logged_context_once:
        log.info("talaria-push context keys: %s", sorted(context.keys()))
        _logged_context_once = True

    url = os.environ.get("TALARIA_PUSH_URL", "").strip()
    secret = os.environ.get("TALARIA_HMAC_SECRET", "").strip()
    if not url or not secret:
        return  # not configured — stay quiet

    session_key = _resolve_session_key(context)
    if not session_key:
        log.warning("talaria-push: no session key resolvable from context; skipping")
        return

    response_text = str(context.get("response") or "").strip()
    payload = {
        "session_id": str(context.get("session_id") or ""),
        "session_key": session_key,
        "title": "Hermes",
        "summary": (response_text[:140] or "Your agent finished a turn."),
    }

    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    signature = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()

    try:
        async with httpx.AsyncClient() as client:
            await client.post(
                f"{url.rstrip('/')}/notify",
                content=body,
                headers={
                    "content-type": "application/json",
                    "X-Talaria-Sig": signature,
                },
                timeout=5,
            )
    except Exception as err:  # never crash the agent over a push
        log.warning("talaria-push: delivery failed: %s", err)
