"""
config.py — Configuration loader for bot-pollerd

Loads config from YAML file with environment variable substitution.
"""

from __future__ import annotations

import os
import re
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml

logger = logging.getLogger(__name__)


# Pattern: ${ENV_VAR} or ${ENV_VAR:default_value}
ENV_VAR_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::([^}]*))?\}")


@dataclass
class FeishuConfig:
    app_id: str = ""
    app_secret: str = ""
    bot_open_id: str = ""


@dataclass
class HermesConfig:
    host: str = "127.0.0.1"
    port: int = 18999


@dataclass
class ChatroomConfig:
    chat_id: str
    mode: str = "at_only"   # "at_only" | "mention_all" | "free_at"
    enabled: bool = True


@dataclass
class PollingConfig:
    interval_seconds: int = 3
    batch_size: int = 20


@dataclass
class PollerConfig:
    feishu: FeishuConfig = field(default_factory=FeishuConfig)
    hermes: HermesConfig = field(default_factory=HermesConfig)
    polling: PollingConfig = field(default_factory=PollingConfig)
    chatrooms: list[ChatroomConfig] = field(default=list)
    free_at_whitelist: list[str] = field(default=list)


def _substitute_env_vars(value: str) -> str:
    """
    Replace ${ENV_VAR} or ${ENV_VAR:default} patterns with environment variable values.
    """
    def replacer(m):
        env_var = m.group(1)
        default = m.group(2)
        val = os.environ.get(env_var)
        if val is not None:
            return val
        if default is not None:
            return default
        logger.warning(f"Environment variable {env_var} not set and no default provided")
        return m.group(0)  # return original if not found

    return ENV_VAR_PATTERN.sub(replacer, value)


def _substitute_dict(obj: dict) -> dict:
    """Recursively substitute env vars in all string values of a dict"""
    result = {}
    for k, v in obj.items():
        if isinstance(v, str):
            result[k] = _substitute_env_vars(v)
        elif isinstance(v, dict):
            result[k] = _substitute_dict(v)
        elif isinstance(v, list):
            result[k] = [
                _substitute_env_vars(i) if isinstance(i, str) else i
                for i in v
            ]
        else:
            result[k] = v
    return result


def load_config(config_path: str | Path | None = None, profile: str = "") -> PollerConfig:
    """
    Load configuration from YAML file.

    Args:
        config_path: Path to pollerd.yaml. If None, uses default locations.
        profile: Hermes profile name (e.g., "bailong", "wukong"). Used to find config_path.

    Default search path (first found wins):
      1. Explicit config_path argument
      2. ~/.hermes/profiles/<profile>/pollerd.yaml
      3. ./pollerd.yaml (current working directory)
    """
    if config_path:
        path = Path(config_path)
    elif profile:
        path = Path.home() / ".hermes" / "profiles" / profile / "pollerd.yaml"
    else:
        # Try default locations
        candidates = [
            Path.home() / ".hermes" / "profiles" / "bailong" / "pollerd.yaml",
            Path("pollerd.yaml"),
        ]
        for candidate in candidates:
            if candidate.exists():
                path = candidate
                break
        else:
            raise FileNotFoundError(
                f"Config file not found. Tried: {candidates}\n"
                "Please provide --config or run with a known profile."
            )

    if not path.exists():
        raise FileNotFoundError(f"Config file not found: {path}")

    logger.info(f"Loading config from: {path}")

    with open(path) as f:
        raw = yaml.safe_load(f)

    # Substitute environment variables
    raw = _substitute_dict(raw)

    # Build FeishuConfig
    feishu_raw = raw.get("feishu", {})
    feishu = FeishuConfig(
        app_id=feishu_raw.get("app_id", ""),
        app_secret=feishu_raw.get("app_secret", ""),
        bot_open_id=feishu_raw.get("bot_open_id", ""),
    )

    # Build HermesConfig
    hermes_raw = raw.get("hermes", {})
    hermes = HermesConfig(
        host=hermes_raw.get("host", "127.0.0.1"),
        port=int(hermes_raw.get("port", 18999)),
    )

    # Build PollingConfig
    polling_raw = raw.get("polling", {})
    polling = PollingConfig(
        interval_seconds=int(polling_raw.get("interval_seconds", 3)),
        batch_size=int(polling_raw.get("batch_size", 20)),
    )

    # Build ChatroomConfig list
    chatrooms = []
    for room in raw.get("chatrooms", []):
        chatrooms.append(ChatroomConfig(
            chat_id=room["chat_id"],
            mode=room.get("mode", "at_only"),
            enabled=room.get("enabled", True),
        ))

    # Free_at whitelist
    free_at_whitelist = raw.get("free_at_whitelist", [])

    config = PollerConfig(
        feishu=feishu,
        hermes=hermes,
        polling=polling,
        chatrooms=chatrooms,
        free_at_whitelist=free_at_whitelist,
    )

    _validate_config(config)

    return config


def _validate_config(config: PollerConfig) -> None:
    """Validate required config fields"""
    errors = []

    if not config.feishu.app_id:
        errors.append("feishu.app_id is required")
    if not config.feishu.app_secret:
        errors.append("feishu.app_secret is required")
    if not config.feishu.bot_open_id:
        errors.append("feishu.bot_open_id is required")
    if not config.chatrooms:
        errors.append("At least one chatroom must be configured")

    for room in config.chatrooms:
        if room.mode not in ("at_only", "mention_all", "free_at"):
            errors.append(f"Invalid room mode '{room.mode}' for chatroom {room.chat_id}. Must be one of: at_only, mention_all, free_at")

    if errors:
        raise ValueError("Config validation failed:\n" + "\n".join(f"  - {e}" for e in errors))
