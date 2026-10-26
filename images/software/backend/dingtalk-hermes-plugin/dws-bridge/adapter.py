"""dws-bridge Platform Adapter for Hermes Agent — DingTalk via the dws CLI.

Bridges DingTalk into Hermes under a personal-account identity (NOT a bot) by
spawning ``dws event +listen-im`` long-lived NDJSON subscription processes for
inbound traffic and driving ``dws chat`` commands for outbound traffic. A
device-authorized dws profile (``dws auth login --device``) is required; the
credential store lives on the host volume (``~/.dws``) shared with the dsh
deployment — never run both stacks against the same dws volumes at once.

config.yaml ``gateway.platforms.dws_bridge.extra`` keys: profile, dws_bin (dws),
groups ([]), dm_enabled (true), require_mention (true), trigger_prefix ("/ai "),
allow_writes (false), allowed_users ([] = deny-none unless core allowlist env set),
max_message_length (4000).
Env vars override config.yaml: DWS_PROFILE, DWS_BIN, DWS_BRIDGE_GROUPS,
DWS_BRIDGE_DM_ENABLED, DWS_BRIDGE_REQUIRE_MENTION, DWS_BRIDGE_TRIGGER_PREFIX,
DWS_BRIDGE_ALLOW_WRITES, DWS_BRIDGE_HOME_CHANNEL, DWS_BRIDGE_ALLOWED_USERS,
DWS_BRIDGE_ALLOW_ALL_USERS.
"""

import asyncio
import contextlib
import datetime
import json
import logging
import os
import random
import shutil
import uuid
from typing import Any, Dict, List, Optional, Tuple

from gateway.platforms._shared import (
    get_scoped_secret as _get_scoped_secret,
    seed_extra_from_env as _seed_extra_from_env,
    send_error,
)
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.helpers import MessageDeduplicator, cancel_task
from gateway.platforms.event import MessageEvent, MessageType
from gateway.config import Platform

logger = logging.getLogger(__name__)

_TRUTHY = {"1", "true", "yes"}
_SEND_TIMEOUT = 30.0
_AUTH_TIMEOUT = 30.0
_LISTEN_BACKOFF_INIT = 1.0
_LISTEN_BACKOFF_MAX = 30.0
_DEFAULT_TRIGGER_PREFIX = "/ai "
_MAX_MESSAGE_LENGTH = 4000
_OWN_TRACK_MAX = 2000
# dws reports its own outbound echo with this flag value on the event stream.
_OWN_SEND_FLAG = "DWS"
# Exit code / stderr markers meaning the dws credential store is no longer valid.
_AUTH_EXIT_CODE = 2
_AUTH_MARKERS = ("auth", "token", "login", "unauthor", "credential", "expired")


# ── dws event/field helpers ──────────────────────────────────────────────────

def _env_or_extra(extra: dict, env: str, key: str, default: Any = "") -> Any:
    """Env var overrides config.yaml ``extra``."""
    return _get_scoped_secret(env) or extra.get(key, default)


def _is_auth_failure(exit_code: int, stderr: str) -> bool:
    if exit_code == _AUTH_EXIT_CODE:
        return True
    blob = (stderr or "").lower()
    return any(marker in blob for marker in _AUTH_MARKERS)


def _first_str(obj: dict, *keys: str) -> str:
    """First non-empty string-ish value among *keys* (dotted paths allowed)."""
    for key in keys:
        cur: Any = obj
        for part in key.split("."):
            if not isinstance(cur, dict):
                cur = None
                break
            cur = cur.get(part)
        if cur is not None and str(cur).strip():
            return str(cur).strip()
    return ""


def _extract_text(event: dict) -> str:
    """Tolerant body extraction: the NDJSON text field name is not contractually
    pinned, so try the observed shapes in order (text / content.text / msgContent)."""
    text = _first_str(event, "text", "content.text")
    if text:
        return text
    raw = event.get("msgContent")
    if isinstance(raw, dict):
        return _first_str(raw, "text", "content")
    if isinstance(raw, str) and raw.strip():
        candidate = raw.strip()
        if candidate.startswith("{"):
            try:
                parsed = json.loads(candidate)
            except ValueError:
                return candidate
            if isinstance(parsed, dict):
                return _first_str(parsed, "text", "content") or candidate
        return candidate
    return ""


def _extract_reply(event: dict) -> Tuple[str, str, str]:
    """(ref_msg_id, ref_sender, ref_text) from the event's quote block, tolerating
    both flat and nested shapes."""
    ref = event.get("ref") or event.get("quote") or {}
    if not isinstance(ref, dict):
        ref = {}
    ref_msg_id = _first_str(event, "refMsgId", "ref_msg_id") or _first_str(ref, "msgId", "messageId", "openMessageId")
    ref_sender = _first_str(event, "refSender", "ref_sender") or _first_str(ref, "sender", "senderId", "senderStaffId")
    ref_text = _first_str(ref, "text", "content.text")
    return ref_msg_id, ref_sender, ref_text


def _is_group_event(event: dict, kind: str) -> bool:
    if kind == "group":
        return True
    conv_type = _first_str(event, "conversationType", "conversation_type", "chatType")
    return conv_type.lower() in {"2", "group"}


# ── dws-bridge adapter ───────────────────────────────────────────────────────

class DwsBridgeAdapter(BasePlatformAdapter):
    """DingTalk adapter driving the dws CLI as a subprocess pair (listen + send)."""

    serial_receive_loop = True  # the NDJSON pump awaits each event before reading the next line

    def __init__(self, config, **kwargs):
        super().__init__(config=config, platform=Platform("dws_bridge"))
        extra = getattr(config, "extra", {}) or {}
        self.profile = str(_env_or_extra(extra, "DWS_PROFILE", "profile") or "").strip()
        self.dws_bin = str(_env_or_extra(extra, "DWS_BIN", "dws_bin", "dws") or "dws").strip()
        groups_raw = _env_or_extra(extra, "DWS_BRIDGE_GROUPS", "groups", "")
        if isinstance(groups_raw, (list, tuple)):
            self.groups: List[str] = [str(g).strip() for g in groups_raw if str(g).strip()]
        else:
            self.groups = [g.strip() for g in str(groups_raw or "").split(",") if g.strip()]
        dm_raw = _get_scoped_secret("DWS_BRIDGE_DM_ENABLED")
        self.dm_enabled = dm_raw.lower() in _TRUTHY if dm_raw else bool(extra.get("dm_enabled", True))
        rm_raw = _get_scoped_secret("DWS_BRIDGE_REQUIRE_MENTION")
        self.require_mention = (
            rm_raw.lower() in _TRUTHY if rm_raw else bool(extra.get("require_mention", True)))
        self.trigger_prefix = str(
            _env_or_extra(extra, "DWS_BRIDGE_TRIGGER_PREFIX", "trigger_prefix", _DEFAULT_TRIGGER_PREFIX)
            or _DEFAULT_TRIGGER_PREFIX)
        aw_raw = _get_scoped_secret("DWS_BRIDGE_ALLOW_WRITES")
        self.allow_writes = aw_raw.lower() in _TRUTHY if aw_raw else bool(extra.get("allow_writes", False))
        self.allowed_users: list = extra.get("allowed_users", [])
        self._allowed_users_set: set = {str(u) for u in self.allowed_users if str(u)}
        max_msg = extra.get("max_message_length")
        if max_msg is None:
            with contextlib.suppress(Exception):
                from gateway.platform_registry import platform_registry
                max_msg = platform_registry.get("dws_bridge").max_message_length
        self.max_message_length = int(max_msg or _MAX_MESSAGE_LENGTH)
        self._listen_tasks: List[asyncio.Task] = []
        self._listen_procs: List[asyncio.subprocess.Process] = []
        self._dedup = MessageDeduplicator()
        self._stopping = False
        self._own_keys: Dict[str, None] = {}  # FIFO set: our idempotency keys + returned message ids
        self._msg_senders: Dict[str, str] = {}  # inbound msg_id -> sender id (reply --ref-sender lookup)

    @property
    def name(self) -> str:
        return "DingTalk (dws)"

    # ── own-echo / sender bookkeeping ────────────────────────────────────────

    def _track_own(self, key: str) -> None:
        if not key:
            return
        self._own_keys[key] = None
        while len(self._own_keys) > _OWN_TRACK_MAX:
            self._own_keys.pop(next(iter(self._own_keys)))

    def _is_own(self, *keys: str) -> bool:
        return any(k and k in self._own_keys for k in keys)

    def _remember_sender(self, msg_id: str, sender: str) -> None:
        if not msg_id or not sender:
            return
        self._msg_senders[msg_id] = sender
        while len(self._msg_senders) > _OWN_TRACK_MAX:
            self._msg_senders.pop(next(iter(self._msg_senders)))

    # ── lifecycle ────────────────────────────────────────────────────────────

    def _fail(self, code: str, message: str, *, retryable: bool) -> bool:
        self._set_fatal_error(code, message, retryable=retryable)
        return False

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        """Preflight dws auth, then start one subscription per group plus one for DMs."""
        if not self.profile:
            logger.error("dws-bridge: DWS_PROFILE must be configured")
            return self._fail("config_missing", "DWS_PROFILE must be set (corpId:userId)", retryable=False)
        if not (shutil.which(self.dws_bin) or os.path.isfile(self.dws_bin)):
            return self._fail("dws_missing", f"dws binary not found: {self.dws_bin}", retryable=False)
        if not self.groups and not self.dm_enabled:
            return self._fail(
                "config_missing",
                "nothing to subscribe: set DWS_BRIDGE_GROUPS and/or DWS_BRIDGE_DM_ENABLED=true",
                retryable=False)
        ok, detail = await self._auth_status()
        if not ok:
            return self._fail(
                "dws_auth_failed",
                f"dws auth status failed for profile {self.profile}: {detail} — "
                "re-run `dws auth login --device` against the shared dws volume",
                retryable=False)
        if not self._acquire_platform_lock("dws_bridge", self.profile, f"dws profile {self.profile}"):
            return False
        self._stopping = False
        for gid in self.groups:
            self._listen_tasks.append(asyncio.create_task(self._listen_loop("group", gid)))
        if self.dm_enabled:
            self._listen_tasks.append(asyncio.create_task(self._listen_loop("all-direct", None)))
        self._mark_connected()
        logger.info(
            "dws-bridge: connected (profile=%s, groups=%d, dm=%s, writes=%s)",
            self.profile, len(self.groups), self.dm_enabled, self.allow_writes)
        self._wire_plugin_handlers(None)
        return True

    async def disconnect(self) -> None:
        """Stop subscriptions and release the profile lock."""
        self._stopping = True
        with contextlib.suppress(Exception):
            self._release_platform_lock()
        for proc in list(self._listen_procs):
            if proc.returncode is None:
                with contextlib.suppress(Exception):
                    proc.terminate()
        for task in self._listen_tasks:
            await cancel_task(task)
        self._listen_tasks.clear()
        self._listen_procs.clear()
        self._mark_disconnected()

    # ── dws process driving ──────────────────────────────────────────────────

    async def _run_dws(self, args: List[str], timeout: float = _SEND_TIMEOUT) -> Tuple[int, str, str]:
        """Run one dws CLI invocation; returns (exit_code, stdout, stderr)."""
        try:
            proc = await asyncio.create_subprocess_exec(
                self.dws_bin, *args,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        except FileNotFoundError:
            return 127, "", f"dws binary not found: {self.dws_bin}"
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except TimeoutError:
            with contextlib.suppress(Exception):
                proc.kill()
                await proc.wait()
            return 124, "", f"dws command timed out after {timeout:.0f}s"
        return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

    async def _auth_status(self) -> Tuple[bool, str]:
        code, out, err = await self._run_dws(
            ["--profile", self.profile, "auth", "status", "--format", "json"], timeout=_AUTH_TIMEOUT)
        if code == 0:
            return True, ""
        return False, (err or out).strip()[:300] or f"exit {code}"

    async def _listen_loop(self, kind: str, chat_id: Optional[str]) -> None:
        """Long-lived NDJSON subscription; respawns with backoff until disconnect or auth-fatal."""
        args = [self.dws_bin, "--profile", self.profile, "event", "+listen-im",
                "--kind", kind, "--events", "message"]
        if chat_id:
            args += ["--chat-id", chat_id]
        args += ["--format", "ndjson"]
        label = f"{kind}:{chat_id}" if chat_id else kind
        backoff = _LISTEN_BACKOFF_INIT
        while not self._stopping:
            proc: Optional[asyncio.subprocess.Process] = None
            try:
                proc = await asyncio.create_subprocess_exec(
                    *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                self._listen_procs.append(proc)
                logger.info("dws-bridge: subscription started (%s, pid=%s)", label, proc.pid)
                backoff = _LISTEN_BACKOFF_INIT
                assert proc.stdout is not None
                while True:
                    line = await proc.stdout.readline()
                    if not line:
                        break
                    try:
                        await self._handle_ndjson_line(line, kind, chat_id)
                    except Exception:
                        logger.warning("dws-bridge: error handling event (%s)", label, exc_info=True)
                stderr = ""
                if proc.stderr is not None:
                    with contextlib.suppress(Exception):
                        stderr = (await proc.stderr.read()).decode("utf-8", "replace")
                code = await proc.wait()
                if self._stopping:
                    break
                if _is_auth_failure(code, stderr):
                    logger.error(
                        "dws-bridge: auth failure in subscription %s (exit=%s): %s",
                        label, code, stderr.strip()[:300])
                    self._set_fatal_error(
                        "dws_auth_failed",
                        f"dws subscription {label} lost auth (exit {code}) — "
                        "re-run `dws auth login --device` against the shared dws volume",
                        retryable=False)
                    await self._notify_fatal_error()
                    return
                logger.warning(
                    "dws-bridge: subscription %s exited (code=%s), respawning in %.1fs",
                    label, code, backoff)
            except asyncio.CancelledError:
                if proc is not None and proc.returncode is None:
                    with contextlib.suppress(Exception):
                        proc.terminate()
                        await asyncio.wait_for(proc.wait(), timeout=5.0)
                raise
            except Exception as exc:
                if self._stopping:
                    break
                logger.error("dws-bridge: subscription %s error: %s", label, exc)
            finally:
                if proc is not None and proc in self._listen_procs:
                    self._listen_procs.remove(proc)
            await asyncio.sleep(backoff + random.uniform(0, backoff * 0.5))
            backoff = min(backoff * 2, _LISTEN_BACKOFF_MAX)

    # ── inbound ──────────────────────────────────────────────────────────────

    async def _handle_ndjson_line(self, line: bytes, kind: str, chat_id_hint: Optional[str]) -> None:
        raw = line.decode("utf-8", "replace").strip()
        if not raw or not raw.startswith("{"):
            return
        try:
            event = json.loads(raw)
        except ValueError:
            logger.debug("dws-bridge: skipping non-JSON line: %.200s", raw)
            return
        if not isinstance(event, dict):
            return
        payload = event.get("message") if isinstance(event.get("message"), dict) else event
        # 1) own-send echo: dws marks messages it sent itself.
        if _first_str(payload, "message_ai_send_flag", "messageAiSendFlag") == _OWN_SEND_FLAG:
            return
        msg_id = _first_str(payload, "openMessageId", "messageId", "msgId", "id")
        idem = _first_str(payload, "idempotencyKey", "idempotency_key", "uuid")
        # 2) own-echo by tracked idempotency key / returned message id.
        if self._is_own(msg_id, idem):
            return
        # 3) transport-level replay dedup.
        if self._dedup.is_duplicate(msg_id or raw):
            return
        text = _extract_text(payload)
        if not text:
            return  # media/system events: no text contract yet
        sender_id = _first_str(payload, "senderStaffId", "senderId", "openDingTalkId", "sender", "userId")
        sender_name = _first_str(payload, "senderNick", "senderName", "userName") or sender_id
        chat_id = _first_str(
            payload, "openConversationId", "conversationId", "chatId", "chat_id") or (chat_id_hint or "")
        if not chat_id:
            logger.debug("dws-bridge: dropping event without conversation id: %.200s", raw)
            return
        is_group = _is_group_event(payload, kind)
        chat_type = "group" if is_group else "dm"
        ref_msg_id, ref_sender, ref_text = _extract_reply(payload)
        reply_to_own = bool(ref_msg_id and self._is_own(ref_msg_id))
        if self._allowed_users_set and sender_id not in self._allowed_users_set:
            logger.debug("dws-bridge: ignoring message from unauthorized sender %s", sender_id)
            return
        # Group trigger gate: trigger prefix, or a reply quoting one of our own messages.
        if is_group and self.require_mention:
            prefix = self.trigger_prefix
            if prefix and text.startswith(prefix):
                text = text[len(prefix):].strip()
            elif reply_to_own:
                pass
            else:
                return
        if not text:
            return
        self._remember_sender(msg_id, sender_id)
        source = self.build_source(
            chat_id=chat_id, chat_name=chat_id, chat_type=chat_type,
            user_id=sender_id or None, user_name=sender_name or None,
            message_id=msg_id or None)
        await self.handle_message(MessageEvent(
            text=text, message_type=MessageType.TEXT, source=source,
            raw_message=payload,
            message_id=msg_id or uuid.uuid4().hex,
            reply_to_message_id=ref_msg_id or None,
            reply_to_text=ref_text or None,
            reply_to_author_id=ref_sender or None,
            reply_to_is_own_message=reply_to_own,
            timestamp=datetime.datetime.now()))

    # ── outbound ─────────────────────────────────────────────────────────────

    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[dict[str, Any]] = None) -> SendResult:
        if not self.allow_writes:
            return SendResult(
                success=False, error="dws-bridge writes disabled (DWS_BRIDGE_ALLOW_WRITES=false)",
                error_kind="forbidden")
        if not chat_id:
            return SendResult(success=False, error="empty chat_id", error_kind="not_found")
        chunks = self.truncate_message(content, self.max_message_length)
        last_result = SendResult(success=False, error="no chunks", error_kind="unknown")
        continuation: List[str] = []
        for index, chunk in enumerate(chunks):
            result = await self._send_chunk(
                chat_id, chunk, reply_to=reply_to if index == 0 else None, metadata=metadata)
            if not result.success:
                return result
            if index == 0:
                last_result = result
            elif result.message_id:
                continuation.append(result.message_id)
        last_result.continuation_message_ids = tuple(continuation)
        return last_result

    async def _send_chunk(self, chat_id: str, content: str, *,
                          reply_to: Optional[str], metadata: Optional[dict[str, Any]]) -> SendResult:
        idem = uuid.uuid4().hex[:128]
        is_group = chat_id in self.groups
        ref_sender = ""
        if is_group and reply_to:
            ref_sender = self._msg_senders.get(reply_to, "")
        if is_group and reply_to and ref_sender:
            args = ["--profile", self.profile, "chat", "message", "reply",
                    "--group", chat_id, "--ref-msg-id", reply_to, "--ref-sender", ref_sender,
                    "--content", content, "--uuid", idem, "--format", "json", "--yes"]
        else:
            target = ["--group", chat_id] if is_group else ["--user", chat_id]
            args = ["--profile", self.profile, "chat", "+messages-send", "--as", "user",
                    *target, "--text", content, "--idempotency-key", idem,
                    "--format", "json", "--yes"]
        try:
            code, out, err = await self._run_dws(args, timeout=_SEND_TIMEOUT)
        except Exception as exc:
            return SendResult(success=False, error=str(exc), retryable=True, error_kind="transient")
        if code != 0:
            blob = (err or out).strip()
            kind = _classify_dws_error(code, blob)
            return SendResult(
                success=False, error=f"dws send failed (exit {code}): {blob[:300]}",
                retryable=kind in {"transient", "rate_limited"}, error_kind=kind)
        msg_id = ""
        with contextlib.suppress(ValueError):
            parsed = json.loads(out.strip() or "{}")
            if isinstance(parsed, dict):
                msg_id = _first_str(parsed, "openMessageId", "messageId", "msgId", "data.openMessageId",
                                    "data.messageId", "processQueryKey")
        self._track_own(idem)
        if msg_id:
            self._track_own(msg_id)
        return SendResult(success=True, message_id=msg_id or idem)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        """DingTalk personal-account sends have no typing indicator — no-op."""

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        return {"name": chat_id, "type": "group" if chat_id in self.groups else "dm"}


def _classify_dws_error(exit_code: int, blob: str) -> str:
    """Map a failed dws send to a SEND_ERROR_KINDS member."""
    if _is_auth_failure(exit_code, blob):
        return "forbidden"
    lowered = (blob or "").lower()
    if "rate" in lowered or "frequent" in lowered or "limit" in lowered:
        return "rate_limited"
    if "not found" in lowered or "not exist" in lowered:
        return "not_found"
    if "permission" in lowered or "forbidden" in lowered:
        return "forbidden"
    if "timeout" in lowered or "timed out" in lowered or "connection" in lowered:
        return "transient"
    return "unknown"


# ── Plugin registration ──────────────────────────────────────────────────────

def _profile_configured() -> str:
    return str(_get_scoped_secret("DWS_PROFILE", "") or "").strip()


def check_requirements() -> bool:
    """Passive probe: dws binary present and a profile configured."""
    return bool(_profile_configured()) and bool(
        shutil.which(str(_get_scoped_secret("DWS_BIN", "") or "dws")))


def validate_config(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    profile = _env_or_extra(extra, "DWS_PROFILE", "profile")
    if not profile:
        return False
    groups = _env_or_extra(extra, "DWS_BRIDGE_GROUPS", "groups", "")
    dm_raw = _get_scoped_secret("DWS_BRIDGE_DM_ENABLED")
    dm_enabled = dm_raw.lower() in _TRUTHY if dm_raw else bool(extra.get("dm_enabled", True))
    return bool(groups or dm_enabled)


def is_connected(config) -> bool:
    return validate_config(config)


def _env_enablement() -> Optional[dict]:
    """``env_enablement_fn``: seed PlatformConfig.extra from env BEFORE adapter construction;
    None when no profile is configured."""
    profile = _profile_configured()
    if not profile:
        return None
    seed = _seed_extra_from_env(
        (("DWS_BIN", "dws_bin", None),
         ("DWS_BRIDGE_GROUPS", "groups", None),
         ("DWS_BRIDGE_DM_ENABLED", "dm_enabled", lambda v: v.lower() in _TRUTHY),
         ("DWS_BRIDGE_REQUIRE_MENTION", "require_mention", lambda v: v.lower() in _TRUTHY),
         ("DWS_BRIDGE_TRIGGER_PREFIX", "trigger_prefix", None),
         ("DWS_BRIDGE_ALLOW_WRITES", "allow_writes", lambda v: v.lower() in _TRUTHY)),
        home_env="DWS_BRIDGE_HOME_CHANNEL")
    return {"profile": profile, **seed}


async def _standalone_send(pconfig, chat_id: str, message: str, *, thread_id: Optional[str] = None,
                           media_files: Optional[list[str]] = None,
                           force_document: bool = False) -> dict[str, Any]:
    """Out-of-process cron delivery via ``send_message_tool``: one dws CLI invocation,
    no live adapter required. Honours the same DWS_BRIDGE_ALLOW_WRITES master gate.
    ``thread_id``/``media_files`` are accepted for signature parity only."""
    extra = getattr(pconfig, "extra", {}) or {}
    aw_raw = _get_scoped_secret("DWS_BRIDGE_ALLOW_WRITES")
    allow_writes = aw_raw.lower() in _TRUTHY if aw_raw else bool(extra.get("allow_writes", False))
    if not allow_writes:
        return send_error("dws-bridge standalone send: writes disabled (DWS_BRIDGE_ALLOW_WRITES=false)")
    profile = str(_env_or_extra(extra, "DWS_PROFILE", "profile") or "").strip()
    if not profile:
        return send_error("dws-bridge standalone send: DWS_PROFILE not configured")
    dws_bin = str(_env_or_extra(extra, "DWS_BIN", "dws_bin", "dws") or "dws").strip()
    if not chat_id:
        home = getattr(pconfig, "home_channel", None)
        chat_id = getattr(home, "chat_id", "") if home else ""
    if not chat_id:
        return send_error("dws-bridge standalone send: no chat_id and no home channel configured")
    idem = uuid.uuid4().hex[:128]
    groups_raw = _env_or_extra(extra, "DWS_BRIDGE_GROUPS", "groups", "")
    if isinstance(groups_raw, (list, tuple)):
        groups = [str(g).strip() for g in groups_raw if str(g).strip()]
    else:
        groups = [g.strip() for g in str(groups_raw or "").split(",") if g.strip()]
    target = ["--group", chat_id] if chat_id in groups else ["--user", chat_id]
    args = [dws_bin, "--profile", profile, "chat", "+messages-send", "--as", "user",
            *target, "--text", message, "--idempotency-key", idem, "--format", "json", "--yes"]
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), timeout=_SEND_TIMEOUT)
    except FileNotFoundError:
        return send_error(f"dws-bridge standalone send: dws binary not found: {dws_bin}")
    except TimeoutError:
        return send_error(f"dws-bridge standalone send: timed out after {_SEND_TIMEOUT:.0f}s")
    except Exception as exc:
        return send_error(f"dws-bridge standalone send failed: {exc}")
    if proc.returncode:
        return send_error(
            f"dws-bridge standalone send failed (exit {proc.returncode}): "
            f"{(err or out).decode('utf-8', 'replace').strip()[:300]}")
    msg_id = ""
    with contextlib.suppress(ValueError):
        parsed = json.loads(out.decode("utf-8", "replace").strip() or "{}")
        if isinstance(parsed, dict):
            msg_id = _first_str(parsed, "openMessageId", "messageId", "msgId", "processQueryKey")
    return {"success": True, "message_id": msg_id or idem}


def register(ctx):
    """Plugin entry point: called by the Hermes plugin system."""
    ctx.register_platform(
        name="dws_bridge",
        dashboard_description="Relay messages between DingTalk (via the dws CLI) and Hermes.",
        docs_url="",
        label="DingTalk (dws bridge)",
        adapter_factory=DwsBridgeAdapter,
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["DWS_PROFILE"],
        install_hint="Requires the dws CLI on PATH and a device-authorized profile",
        env_enablement_fn=_env_enablement,  # env-only setups show in gateway status
        cron_deliver_env_var="DWS_BRIDGE_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,  # cron running separately from the gateway
        allowed_users_env="DWS_BRIDGE_ALLOWED_USERS",
        allow_all_env="DWS_BRIDGE_ALLOW_ALL_USERS",
        max_message_length=_MAX_MESSAGE_LENGTH,
        emoji="💼",
        pii_safe=False,  # DingTalk accounts carry real names/phone numbers
        allow_update_command=True,
        platform_hint=(
            "You are chatting via DingTalk (personal account bridge). Plain text "
            "is safest; simple markdown renders in some clients but do not rely "
            "on it. Long messages are automatically split. In group chats you "
            "are triggered by the configured prefix or when someone replies to "
            "your own message. Keep responses concise and conversational."))
