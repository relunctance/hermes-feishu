"""
poller.py — Feishu API message poller

Polls Feishu API every N seconds to fetch new group messages.
Handles token management, message deduplication, and free_at mode.
"""

from __future__ import annotations

import logging
import time
from typing import Optional

import requests

from config import PollerConfig, ChatroomConfig
from message_parser import MessageParser, ParsedMessage
from http_forwarder import HttpForwarder

logger = logging.getLogger(__name__)

# Feishu API endpoints
FEISHU_TOKEN_URL = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
FEISHU_MESSAGES_URL = "https://open.feishu.cn/open-apis/im/v1/messages"


class FeishuApiError(Exception):
    """Feishu API error with code"""
    def __init__(self, code: int, msg: str):
        self.code = code
        self.msg = msg
        super().__init__(f"[{code}] {msg}")


class TokenManager:
    """
    Manages Feishu tenant access token with automatic refresh.
    Token is cached and refreshed when it expires (2 hour TTL).
    """

    def __init__(self, app_id: str, app_secret: str):
        self.app_id = app_id
        self.app_secret = app_secret
        self._token: Optional[str] = None
        self._expires_at: float = 0  # unix timestamp

    def get_token(self) -> str:
        """Get current valid token, refreshing if expired"""
        if not self._token or time.time() >= self._expires_at - 60:
            self._refresh()
        return self._token

    def _refresh(self) -> None:
        """Request new access token from Feishu"""
        resp = requests.post(
            FEISHU_TOKEN_URL,
            json={
                "app_id": self.app_id,
                "app_secret": self.app_secret,
            },
            timeout=10,
        )
        data = resp.json()
        if data.get("code") != 0:
            raise FeishuApiError(data.get("code", -1), data.get("msg", "unknown"))
        self._token = data["tenant_access_token"]
        # Token TTL is typically 2 hours, mark expires 1 min early for safety
        self._expires_at = time.time() + data.get("expire", 7200) - 60
        logger.info(f"Feishu token refreshed, expires in {data.get('expire', 7200)}s")


class FeishuMessagePoller:
    """
    Polls Feishu group messages and forwards relevant ones to Hermes.

    Uses last_processed_message_id per chatroom to avoid reprocessing.
    On startup, uses a time window (messages from last 5 minutes) to avoid
    reprocessing history.
    """

    def __init__(
        self,
        config: PollerConfig,
        forwarder: HttpForwarder,
        parser: MessageParser,
    ):
        self.config = config
        self.forwarder = forwarder
        self.parser = parser

        self._token_manager = TokenManager(
            config.feishu.app_id,
            config.feishu.app_secret,
        )

        # Per-chatroom state
        # chat_id -> last processed message_id (for deduplication)
        self._last_processed_ids: dict[str, str] = {}
        # chat_id -> mode (resolved from config)
        self._chatroom_modes: dict[str, str] = {r.chat_id: r.mode for r in config.chatrooms}
        # chat_id -> enabled
        self._chatroom_enabled: dict[str, bool] = {r.chat_id: r.enabled for r in config.chatrooms}

    def get_room_mode(self, chat_id: str) -> str:
        """Get the mode for a specific chatroom"""
        return self._chatroom_modes.get(chat_id, "at_only")

    def poll_once(self) -> int:
        """
        Single poll cycle across all chatrooms.

        Returns:
            Number of messages successfully forwarded to Hermes
        """
        token = self._token_manager.get_token()
        headers = {"Authorization": f"Bearer {token}"}
        success_count = 0

        for room in self.config.chatrooms:
            if not room.enabled:
                continue

            try:
                messages = self._fetch_messages(headers, room.chat_id)
                new_messages = self._filter_new(messages, room.chat_id)
                logger.debug(
                    f"Chatroom {room.chat_id}: fetched {len(messages)}, "
                    f"{len(new_messages)} new"
                )

                for raw in new_messages:
                    parsed = self.parser.parse(raw, room.mode)
                    if parsed:
                        if self.forwarder.forward(parsed):
                            self._mark_processed(parsed.message_id, room.chat_id)
                            success_count += 1
                        else:
                            logger.warning(
                                f"Skipping mark_processed for failed forward: "
                                f"{parsed.message_id}"
                            )

            except FeishuApiError as e:
                if e.code == 230013:
                    # Rate limited — back off
                    logger.warning(f"Rate limited by Feishu, pausing")
                    time.sleep(5)
                elif e.code == 230001:
                    logger.warning(f"Bot not in chatroom {room.chat_id}, skipping")
                else:
                    logger.error(f"Feishu API error for {room.chat_id}: {e}")
            except Exception as e:
                logger.error(f"Unexpected error polling {room.chat_id}: {e}")

        return success_count

    def _fetch_messages(self, headers: dict, chat_id: str) -> list[dict]:
        """
        Fetch recent messages from Feishu API.

        Uses sort_type=ByCreateTimeDesc to get newest first.
        Limits to polling.batch_size messages.
        """
        params = {
            "container_id_type": "chat",
            "container_id": chat_id,
            "sort_type": "ByCreateTimeDesc",
            "page_size": str(self.config.polling.batch_size),
        }
        resp = requests.get(
            FEISHU_MESSAGES_URL,
            headers=headers,
            params=params,
            timeout=10,
        )
        data = resp.json()

        if data.get("code") != 0:
            raise FeishuApiError(data.get("code", -1), data.get("msg", "unknown"))

        items = data.get("data", {}).get("items", [])
        return items

    def _filter_new(self, messages: list[dict], chat_id: str) -> list[dict]:
        """
        Filter out already-processed messages.

        If this is the first poll for a chatroom (no last_processed_id),
        apply a 5-minute time window to avoid reprocessing history.
        """
        last_id = self._last_processed_ids.get(chat_id)

        if not last_id:
            # First poll — apply time window filter
            cutoff = time.time() - 300  # 5 minutes ago
            filtered = []
            for msg in messages:
                create_time = int(msg.get("create_time", "0"))
                if create_time >= cutoff:
                    filtered.append(msg)
            return filtered

        # Find the index of last_processed_id, return only newer messages
        for i, msg in enumerate(messages):
            if msg.get("message_id") == last_id:
                return messages[:i]
        # last_id not found in current results — treat all as new (gap is fine)
        return messages[: self.config.polling.batch_size]

    def _mark_processed(self, message_id: str, chat_id: str) -> None:
        """Record that a message was successfully processed"""
        self._last_processed_ids[chat_id] = message_id
