"""dws-bridge platform plugin — bridges DingTalk (via the dws CLI) into Hermes."""

from .adapter import register

__all__ = ["register"]
