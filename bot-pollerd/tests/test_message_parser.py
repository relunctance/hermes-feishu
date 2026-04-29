"""
test_message_parser.py — TDD tests for message_parser.py
"""

import pytest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from message_parser import MessageParser, ParsedMessage


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

MY_OPEN_ID = "ou_my_bot"
WHITELIST = ["ou_bailong", "ou_wukong", "ou_mao"]


@pytest.fixture
def parser():
    return MessageParser(my_open_id=MY_OPEN_ID, free_at_whitelist=WHITELIST)


def make_raw_message(
    message_id="om_1",
    chat_id="oc_chat1",
    sender_open_id="ou_user1",
    sender_type="user",
    body_text="@wk-hermes hello",
    mentions=None,
):
    """Build a raw Feishu message dict"""
    if mentions is None:
        mentions = [
            {"key": "@_user_1", "id": {"open_id": "ou_wk_hermes"}, "name": "wk-hermes"}
        ]
    return {
        "message_id": message_id,
        "chat_id": chat_id,
        "sender": {
            "sender_type": sender_type,
            "sender_id": {"open_id": sender_open_id},
        },
        "body": {"content": f'{{"text": "{body_text}"}}'},
        "mentions": mentions,
        "create_time": "1700000000",
    }


# ---------------------------------------------------------------------------
# Tests: _should_handle
# ---------------------------------------------------------------------------

class TestShouldHandle:
    def test_at_only_requires_mentioned_me(self, parser):
        assert parser._should_handle("at_only", mentioned_me=True, is_free_at=False) is True
        assert parser._should_handle("at_only", mentioned_me=False, is_free_at=False) is False

    def test_mention_all_requires_mentioned_me(self, parser):
        assert parser._should_handle("mention_all", mentioned_me=True, is_free_at=False) is True
        assert parser._should_handle("mention_all", mentioned_me=False, is_free_at=False) is False

    def test_free_at_requires_free_at_message(self, parser):
        assert parser._should_handle("free_at", mentioned_me=False, is_free_at=True) is True
        assert parser._should_handle("free_at", mentioned_me=False, is_free_at=False) is False

    def test_unknown_mode_skips(self, parser):
        assert parser._should_handle("unknown", mentioned_me=True, is_free_at=True) is False


# ---------------------------------------------------------------------------
# Tests: parse basic
# ---------------------------------------------------------------------------

class TestParseBasic:
    def test_parse_normal_message(self, parser):
        raw = make_raw_message(
            message_id="om_abc",
            chat_id="oc_group1",
            sender_open_id="ou_user1",
            sender_type="user",
            body_text="hello",
            mentions=[],
        )
        # Not mentioned, not free_at, so skipped in all modes
        assert parser.parse(raw, room_mode="at_only") is None

    def test_parse_mentioned_me_true(self, parser):
        raw = make_raw_message(
            message_id="om_abc",
            chat_id="oc_group1",
            sender_open_id="ou_user1",
            sender_type="user",
            body_text="@wk-hermes hi",
            mentions=[{"key": "@_user_1", "id": {"open_id": MY_OPEN_ID}, "name": "my-bot"}],
        )
        result = parser.parse(raw, room_mode="at_only")
        assert result is not None
        assert result.message_id == "om_abc"
        assert result.mentioned_me is True
        assert result.is_free_at_message is False

    def test_parse_sender_type_bot(self, parser):
        raw = make_raw_message(
            message_id="om_bot_msg",
            chat_id="oc_group1",
            sender_open_id="ou_bailong",
            sender_type="bot",
            body_text="@wk-hermes what model?",
            mentions=[{"key": "@_user_1", "id": {"open_id": MY_OPEN_ID}, "name": "my-bot"}],
        )
        result = parser.parse(raw, room_mode="at_only")
        assert result is not None
        assert result.sender_type == "bot"
        assert result.sender_open_id == "ou_bailong"


# ---------------------------------------------------------------------------
# Tests: ignore self (prevent infinite loop)
# ---------------------------------------------------------------------------

class TestIgnoreSelf:
    def test_ignore_self_at_only_message(self, parser):
        """Bot's own @ message should be ignored"""
        raw = make_raw_message(
            message_id="om_self",
            chat_id="oc_group1",
            sender_open_id=MY_OPEN_ID,  # myself
            sender_type="bot",
            body_text="@wk-hermes who are you",
            mentions=[{"key": "@_user_1", "id": {"open_id": MY_OPEN_ID}, "name": "my-bot"}],
        )
        result = parser.parse(raw, room_mode="at_only")
        assert result is None

    def test_ignore_self_free_at_message(self, parser):
        """Bot's own free_at message should also be ignored"""
        raw = make_raw_message(
            message_id="om_self_free_at",
            chat_id="oc_group1",
            sender_open_id=MY_OPEN_ID,  # myself
            sender_type="bot",
            body_text="my own free_at message",
            mentions=[],  # no mentions
        )
        result = parser.parse(raw, room_mode="free_at")
        assert result is None


# ---------------------------------------------------------------------------
# Tests: free_at mode
# ---------------------------------------------------------------------------

class TestFreeAtMode:
    def test_free_at_whitelisted_bot(self, parser):
        """Whitelisted bot sending no-mention message = free_at message"""
        raw = make_raw_message(
            message_id="om_no_mention",
            chat_id="oc_group1",
            sender_open_id="ou_bailong",  # in whitelist
            sender_type="bot",
            body_text="weather is nice today",
            mentions=[],  # no mentions
        )
        result = parser.parse(raw, room_mode="free_at")
        assert result is not None
        assert result.is_free_at_message is True
        assert result.mentioned_me is False

    def test_free_at_not_whitelisted(self, parser):
        """Bot not in whitelist sending no-mention message = ignored"""
        raw = make_raw_message(
            message_id="om_unknown",
            chat_id="oc_group1",
            sender_open_id="ou_unknown_bot",  # not in whitelist
            sender_type="bot",
            body_text="random message",
            mentions=[],
        )
        result = parser.parse(raw, room_mode="free_at")
        assert result is None

    def test_free_at_human_not_in_whitelist(self, parser):
        """Human sending no-mention message, not in whitelist = ignored"""
        raw = make_raw_message(
            message_id="om_human",
            chat_id="oc_group1",
            sender_open_id="ou_human",
            sender_type="user",
            body_text="human message",
            mentions=[],
        )
        result = parser.parse(raw, room_mode="free_at")
        assert result is None

    def test_free_at_whitelisted_human(self, parser):
        """Human in whitelist sending no-mention message = free_at"""
        raw = make_raw_message(
            message_id="om_human_whitelist",
            chat_id="oc_group1",
            sender_open_id="ou_mao",  # in whitelist (even though type=user)
            sender_type="user",
            body_text="from whitelisted human",
            mentions=[],
        )
        result = parser.parse(raw, room_mode="free_at")
        assert result is not None
        assert result.is_free_at_message is True


# ---------------------------------------------------------------------------
# Tests: room_mode combinations
# ---------------------------------------------------------------------------

class TestRoomModeCombinations:
    def test_at_only_mode_bot_mentions_other(self, parser):
        """at_only mode: message mentions other bot but not me = skip"""
        raw = make_raw_message(
            message_id="om_mention_other",
            chat_id="oc_group1",
            sender_open_id="ou_bailong",
            sender_type="bot",
            body_text="@other-bot hi",
            mentions=[{"key": "@_user_1", "id": {"open_id": "ou_other"}, "name": "other"}],
        )
        result = parser.parse(raw, room_mode="at_only")
        assert result is None

    def test_mention_all_mode_bot_mentions_human(self, parser):
        """mention_all: message mentions human (not me) = skip"""
        raw = make_raw_message(
            message_id="om_mention_human",
            chat_id="oc_group1",
            sender_open_id="ou_bailong",
            sender_type="bot",
            body_text="@zhangsan hi",
            mentions=[{"key": "@_user_1", "id": {"open_id": "ou_zhangsan"}, "name": "zhangsan"}],
        )
        # ou_zhangsan is not MY open_id, so mentioned_me=False
        result = parser.parse(raw, room_mode="mention_all")
        assert result is None


# ---------------------------------------------------------------------------
# Tests: body parsing
# ---------------------------------------------------------------------------

class TestBodyParsing:
    def test_body_plain_text_not_json(self, parser):
        """Plain text body (not JSON) = treated as raw text"""
        raw = {
            "message_id": "om_plain",
            "chat_id": "oc_group1",
            "sender": {"sender_type": "bot", "sender_id": {"open_id": "ou_bailong"}},
            "body": {"content": "This is plain text, not JSON"},
            "mentions": [],
        }
        # ou_bailong IS in whitelist, so free_at mode returns ParsedMessage
        result = parser.parse(raw, room_mode="free_at")
        assert result is not None
        assert result.text == "This is plain text, not JSON"

    def test_body_empty_json(self, parser):
        """body.content = {}"""
        raw = {
            "message_id": "om_empty",
            "chat_id": "oc_group1",
            "sender": {"sender_type": "bot", "sender_id": {"open_id": "ou_bailong"}},
            "body": {"content": "{}"},
            "mentions": [],
        }
        # In whitelist, so free_at mode returns message (text="")
        result = parser.parse(raw, room_mode="free_at")
        assert result is not None
        assert result.text == ""


# ---------------------------------------------------------------------------
# Tests: edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    def test_missing_sender_field(self, parser):
        raw = {
            "message_id": "om_no_sender",
            "chat_id": "oc_group1",
            "body": {"content": '{"text": "test"}'},
            "mentions": [],
        }
        result = parser.parse(raw, room_mode="free_at")
        assert result is None

    def test_missing_body_field(self, parser):
        """body field missing = text defaults to empty string"""
        raw = {
            "message_id": "om_no_body",
            "chat_id": "oc_group1",
            "sender": {"sender_type": "bot", "sender_id": {"open_id": "ou_bailong"}},
            "mentions": [],
        }
        # ou_bailong is in whitelist, so it's a free_at message (text="")
        result = parser.parse(raw, room_mode="free_at")
        assert result is not None
        assert result.text == ""

    def test_missing_mentions_field(self, parser):
        """mentions field missing entirely = treated as empty list"""
        raw = {
            "message_id": "om_no_mentions",
            "chat_id": "oc_group1",
            "sender": {"sender_type": "bot", "sender_id": {"open_id": "ou_bailong"}},
            "body": {"content": '{"text": "test"}'},
        }
        # mentions missing, but sender is in whitelist
        result = parser.parse(raw, room_mode="free_at")
        assert result is not None
        assert result.is_free_at_message is True


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
