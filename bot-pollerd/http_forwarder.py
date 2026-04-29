"""
http_forwarder.py — Forward parsed messages to Hermes via HTTP
"""

from __future__ import annotations

import logging
from typing import Optional

import requests

from message_parser import ParsedMessage

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_SECONDS = 5
MAX_RETRIES = 3
RETRY_DELAY_SECONDS = 1.0


class HttpForwarder:
    """
    Forward parsed Feishu messages to Hermes Webhook endpoint via HTTP POST.

    The Hermes side needs to expose a /webhook/poll endpoint.
    If Hermes is unreachable, messages are retried with exponential backoff.
    """

    def __init__(
        self,
        hermes_host: str,
        hermes_port: int,
        timeout: int = DEFAULT_TIMEOUT_SECONDS,
    ):
        self.base_url = f"http://{hermes_host}:{hermes_port}"
        self.timeout = timeout

    def forward(self, parsed: ParsedMessage) -> bool:
        """
        HTTP POST a parsed message to Hermes Webhook.

        Args:
            parsed: ParsedMessage from message_parser

        Returns:
            True if Hermes returned 200, False otherwise
        """
        payload = {
            "message_id": parsed.message_id,
            "chat_id": parsed.chat_id,
            "sender_open_id": parsed.sender_open_id,
            "sender_type": parsed.sender_type,
            "sender_name": parsed.sender_name,
            "text": parsed.text,
            "mentioned_me": parsed.mentioned_me,
            "is_free_at_message": parsed.is_free_at_message,
        }

        url = f"{self.base_url}/webhook/poll"
        last_error = None

        for attempt in range(1, MAX_RETRIES + 1):
            try:
                resp = requests.post(
                    url,
                    json=payload,
                    timeout=self.timeout,
                    headers={"Content-Type": "application/json"},
                )
                if resp.status_code == 200:
                    logger.info(
                        f"Forward success: {parsed.message_id} "
                        f"from {parsed.sender_open_id} ({parsed.sender_type})"
                    )
                    return True
                else:
                    logger.warning(
                        f"Hermes returned {resp.status_code} for {parsed.message_id}, "
                        f"attempt {attempt}/{MAX_RETRIES}"
                    )
                    last_error = f"HTTP {resp.status_code}"

            except requests.Timeout:
                logger.warning(
                    f"Timeout forwarding {parsed.message_id}, "
                    f"attempt {attempt}/{MAX_RETRIES}"
                )
                last_error = "timeout"

            except requests.RequestException as e:
                logger.warning(
                    f"Forward error for {parsed.message_id}: {e}, "
                    f"attempt {attempt}/{MAX_RETRIES}"
                )
                last_error = str(e)

            if attempt < MAX_RETRIES:
                import time
                time.sleep(RETRY_DELAY_SECONDS * attempt)

        logger.error(
            f"Forward failed after {MAX_RETRIES} attempts: "
            f"{parsed.message_id}, last_error={last_error}"
        )
        return False
