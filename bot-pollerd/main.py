"""
bot-pollerd — Bot-to-Bot polling service

Entry point: python -m bot_pollerd --profile <profile>
"""

from __future__ import annotations

import argparse
import logging
import sys
import time

from config import load_config
from poller import FeishuMessagePoller
from message_parser import MessageParser
from http_forwarder import HttpForwarder

__version__ = "1.0.0"

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("bot-pollerd")


def main() -> None:
    parser = argparse.ArgumentParser(description="bot-pollerd: Feishu bot-to-bot polling service")
    parser.add_argument("--profile", type=str, default="", help="Hermes profile name (e.g. mao, bailong)")
    parser.add_argument("--config", type=str, default="", help="Path to pollerd.yaml")
    parser.add_argument("--dry-run", action="store_true", help="Validate config and exit without polling")
    args = parser.parse_args()

    # Load config
    try:
        config = load_config(config_path=args.config or None, profile=args.profile)
    except FileNotFoundError as e:
        logger.error(f"Config not found: {e}")
        sys.exit(1)
    except ValueError as e:
        logger.error(f"Config error: {e}")
        sys.exit(1)

    logger.info(f"bot-pollerd v{__version__} starting")
    logger.info(f"  bot_open_id: {config.feishu.bot_open_id}")
    logger.info(f"  app_id: {config.feishu.app_id}")
    logger.info(f"  hermes: {config.hermes.host}:{config.hermes.port}")
    logger.info(f"  chatrooms: {len(config.chatrooms)}")

    if args.dry_run:
        logger.info("Dry-run: config valid, exiting")
        return

    # Build components
    forwarder = HttpForwarder(
        hermes_host=config.hermes.host,
        hermes_port=config.hermes.port,
    )
    message_parser = MessageParser(
        my_open_id=config.feishu.bot_open_id,
        free_at_whitelist=config.free_at_whitelist,
    )
    poller = FeishuMessagePoller(
        config=config,
        forwarder=forwarder,
        parser=message_parser,
    )

    logger.info("Poller started, entering main loop")

    consecutive_errors = 0
    max_consecutive_errors = 10

    while True:
        try:
            count = poller.poll_once()
            consecutive_errors = 0
            if count > 0:
                logger.info(f"Poll cycle done: {count} messages forwarded")
        except Exception as e:
            consecutive_errors += 1
            logger.error(f"Poll cycle error ({consecutive_errors}/{max_consecutive_errors}): {e}")
            if consecutive_errors >= max_consecutive_errors:
                logger.critical(f"Too many consecutive errors, exiting")
                sys.exit(1)

        time.sleep(config.polling.interval_seconds)


if __name__ == "__main__":
    main()
