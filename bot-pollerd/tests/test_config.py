"""
test_config.py — Tests for config.py
"""

import pytest
import tempfile
import os
import sys
import pathlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config import load_config, PollerConfig, FeishuConfig, HermesConfig


class TestEnvVarSubstitution:
    def test_env_var_replaced(self):
        """${VAR} should be replaced with os.environ[VAR]"""
        os.environ["TEST_APP_ID"] = "cli_test_123"
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(f"""feishu:
  app_id: ${{TEST_APP_ID}}
  app_secret: secret
  bot_open_id: ou_test
chatrooms:
  - chat_id: oc_test_group
    mode: at_only
""")
            f.flush()
            cfg = load_config(f.name)
        os.unlink(f.name)
        assert cfg.feishu.app_id == "cli_test_123"

    def test_env_var_with_default(self):
        """${VAR:default} should use default if VAR not set"""
        os.environ.pop("TEST_UNSET_VAR", None)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("""feishu:
  app_id: ${TEST_UNSET_VAR:cli_default}
  app_secret: s
  bot_open_id: ou_test
chatrooms:
  - chat_id: oc_test_group
    mode: at_only
""")
            f.flush()
            cfg = load_config(f.name)
        os.unlink(f.name)
        assert cfg.feishu.app_id == "cli_default"

    def test_env_var_missing_no_default(self):
        """${VAR} with no default and no env var keeps original placeholder"""
        os.environ.pop("TEST_MISSING", None)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("""feishu:
  app_id: ${TEST_MISSING}
  app_secret: s
  bot_open_id: ou_test
chatrooms:
  - chat_id: oc_test_group
    mode: at_only
""")
            f.flush()
            cfg = load_config(f.name)
        os.unlink(f.name)
        assert cfg.feishu.app_id == "${TEST_MISSING}"


class TestLoadConfig:
    def test_full_config(self):
        yaml_content = """
feishu:
  app_id: cli_abc
  app_secret: secret123
  bot_open_id: ou_mybot

hermes:
  host: 127.0.0.1
  port: 18999

polling:
  interval_seconds: 3
  batch_size: 20

chatrooms:
  - chat_id: oc_group1
    mode: at_only
    enabled: true
  - chat_id: oc_group2
    mode: free_at
    enabled: true

free_at_whitelist:
  - ou_bot_a
  - ou_bot_b
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            f.flush()
            cfg = load_config(f.name)
        os.unlink(f.name)

        assert cfg.feishu.app_id == "cli_abc"
        assert cfg.feishu.bot_open_id == "ou_mybot"
        assert cfg.hermes.port == 18999
        assert cfg.polling.interval_seconds == 3
        assert len(cfg.chatrooms) == 2
        assert cfg.chatrooms[0].mode == "at_only"
        assert cfg.chatrooms[1].mode == "free_at"
        assert "ou_bot_a" in cfg.free_at_whitelist

    def test_missing_required_field(self):
        """Missing app_id should raise ValueError"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("feishu:\n  app_secret: s\n  bot_open_id: ou_test\n")
            f.flush()
            with pytest.raises(ValueError, match="app_id is required"):
                load_config(f.name)
        os.unlink(f.name)

    def test_invalid_room_mode(self):
        """Invalid room mode should raise ValueError"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("""
feishu:
  app_id: cli_abc
  app_secret: s
  bot_open_id: ou_test
chatrooms:
  - chat_id: oc_group1
    mode: invalid_mode
""")
            f.flush()
            with pytest.raises(ValueError, match="Invalid room mode"):
                load_config(f.name)
        os.unlink(f.name)

    def test_no_chatrooms(self):
        """No chatrooms configured should raise ValueError"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("""
feishu:
  app_id: cli_abc
  app_secret: s
  bot_open_id: ou_test
chatrooms: []
""")
            f.flush()
            with pytest.raises(ValueError, match="At least one chatroom"):
                load_config(f.name)
        os.unlink(f.name)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
