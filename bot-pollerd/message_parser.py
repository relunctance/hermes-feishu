"""
message_parser.py — Feishu message parser for bot-pollerd

Parses raw Feishu group messages, filters out messages that should be handled
by the bot (bot @ bot mentions, free_at broadcast messages).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)


@dataclass
class ParsedMessage:
    """Parsed Feishu message ready for forwarding"""
    message_id: str
    chat_id: str
    sender_open_id: str
    sender_type: str          # "user" | "bot"
    sender_name: str
    text: str                 # message text content
    mentioned_me: bool        # True if this message @mentioned the bot
    is_free_at_message: bool  # True if this is a free_at broadcast message
    raw: dict                 # raw message for debugging


class MessageParser:
    """
    Parse Feishu group messages, filtering for bot-relevant messages.

    Room modes:
      - at_only:      only handle messages that @mention THIS bot
      - mention_all:  handle any message that @mentions ANYONE (human or bot)
      - free_at:      handle free_at messages (no @mentions, sender in whitelist)

    Free_at mode:
      In free_at mode, bots in the whitelist can broadcast messages without
      @mentioning anyone. The bot processes these messages and replies.
      This enables the "免@ broadcast" mode where bots talk to each other
      without explicit @mentions.
    """

    def __init__(self, my_open_id: str, free_at_whitelist: list[str]):
        """
        Args:
            my_open_id:         this bot's open_id (to filter out self-messages)
            free_at_whitelist:  open_ids that are allowed to send free_at messages
        """
        self.my_open_id = my_open_id
        self.free_at_whitelist = free_at_whitelist or []

    def parse(self, raw_message: dict, room_mode: str) -> Optional[ParsedMessage]:
        """
        Parse a single raw Feishu message.

        Args:
            raw_message: raw dict from Feishu API
            room_mode:    "at_only" | "mention_all" | "free_at"

        Returns:
            ParsedMessage if this message should be handled, None if it should be skipped
        """
        try:
            sender = raw_message.get("sender") or {}
            sender_open_id = sender.get("sender_id", {}).get("open_id", "")
            sender_type = sender.get("sender_type", "")

            # Ignore self-sent messages (prevent infinite forwarding loop)
            if sender_open_id == self.my_open_id:
                logger.debug(f"Skipping own message: {raw_message.get('message_id')}")
                return None

            # Extract text from body.content
            text = self._extract_text(raw_message)

            # Parse mentions
            mentions = raw_message.get("mentions") or []
            mentioned_open_ids = [
                m.get("id", {}).get("open_id", "") for m in mentions
            ]
            mentioned_me = self.my_open_id in mentioned_open_ids

            # Determine if this is a free_at message
            # Conditions: no mentions AND sender is in free_at whitelist
            is_free_at = (len(mentions) == 0) and (sender_open_id in self.free_at_whitelist)

            # Decide whether to handle based on room_mode
            if not self._should_handle(room_mode, mentioned_me, is_free_at):
                return None

            # Get sender name (prefer from sender_id, fallback to open_id)
            sender_id = sender.get("sender_id") or {}
            sender_name = sender_id.get("name", "") or sender_open_id

            return ParsedMessage(
                message_id=raw_message.get("message_id", ""),
                chat_id=raw_message.get("chat_id", ""),
                sender_open_id=sender_open_id,
                sender_type=sender_type,
                sender_name=sender_name,
                text=text,
                mentioned_me=mentioned_me,
                is_free_at_message=is_free_at,
                raw=raw_message,
            )

        except Exception as e:
            logger.warning(f"Message parse error: {e}, raw={raw_message}")
            return None

    def _extract_text(self, raw_message: dict) -> str:
        """
        Extract text from body.content.
        Handles both JSON format ({"text": "..."}) and plain text.
        """
        content = raw_message.get("body", {}).get("content", "")
        if not content:
            return ""

        try:
            parsed = json.loads(content)
            return parsed.get("text", "")
        except json.JSONDecodeError:
            # Plain text format
            return content

    def _should_handle(self, mode: str, mentioned_me: bool, is_free_at: bool) -> bool:
        """
        Decision matrix:

        | mode       | mentioned_me | is_free_at | handle? |
        |------------|--------------|------------|---------|
        | at_only    | True         | any        | YES     |
        | at_only    | False        | any        | NO      |
        | mention_all| True         | any        | YES     |
        | mention_all| False        | any        | NO      |
        | free_at    | any          | True       | YES     |
        | free_at    | any          | False      | NO      |
        | (unknown)  | any          | any        | NO      |
        """
        if mode == "at_only":
            return mentioned_me
        elif mode == "mention_all":
            return mentioned_me
        elif mode == "free_at":
            return is_free_at
        else:
            logger.warning(f"Unknown room_mode: {mode}, skipping")
            return False
