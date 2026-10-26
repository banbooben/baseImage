#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
钉钉群桥接守护进程（群级策略 + 多轮上下文）

按群级策略配置文件 config.yaml 监听钉钉消息，交给 Hermes 处理后回复。
- @ 触发：群里有人 @ 我（at-me 订阅，白名单群过滤）
- 关键词触发：群里消息命中该群 keywords（每个群独立 group 订阅）
- 多轮对话：按「群」维度共享缓存最近消息（全群一个上下文），拼进 prompt 保持上下文

环境变量（均可选）：
  DT_BRIDGE_CONFIG         配置文件路径(默认 ~/.local/state/dingtalk-bridge/config.yaml)
  DT_BRIDGE_HERMES_TIMEOUT Hermes 处理超时秒数(默认 300)
  DT_BRIDGE_MAX_REPLY_LEN  回复截断字符数(默认 3000)
  DT_BRIDGE_AT_SENDER      回复时是否 @ 提问人: 1(默认) | 0
  DWS_BIN                  dws 可执行文件路径(默认 PATH 查找，回退 ~/.local/bin/dws)
  HERMES_BIN               hermes 可执行文件路径(默认 PATH 查找)

清理：SIGTERM/SIGINT 会干净退出，dws 子进程收到 SIGTERM 自动取消订阅。
"""
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import threading
import time
from collections import deque
from pathlib import Path

import yaml

DWS = (os.environ.get("DWS_BIN") or shutil.which("dws")
       or str(Path.home() / ".local/bin/dws"))
HERMES = (os.environ.get("HERMES_BIN") or shutil.which("hermes")
          or str(Path.home() / ".local/bin/hermes"))

STATE_DIR = Path(os.environ.get(
    "DT_BRIDGE_STATE_DIR", str(Path.home() / ".local/state/dingtalk-bridge")))
STATE_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = STATE_DIR / "bridge.log"
CONFIG_PATH = Path(os.environ.get("DT_BRIDGE_CONFIG", str(STATE_DIR / "config.yaml")))
HISTORY_PATH = STATE_DIR / "history.json"

HERMES_TIMEOUT = int(os.environ.get("DT_BRIDGE_HERMES_TIMEOUT", "300"))
MAX_REPLY_LEN = int(os.environ.get("DT_BRIDGE_MAX_REPLY_LEN", "3000"))
AT_SENDER = os.environ.get("DT_BRIDGE_AT_SENDER", "1") == "1"
HISTORY_CAP = 200          # 每个群最多存储条数
DEFAULT_HISTORY_SIZE = 10  # 默认上下文窗口

_shutdown = threading.Event()
_procs = []                 # 所有订阅子进程
_procs_lock = threading.Lock()
_event_queue = queue.Queue()

# 消息缓存: {conv_id: deque}（按群共享，全群一个上下文）
_history = {}
_history_lock = threading.Lock()

# 当前群配置（启动/订阅重启时加载，worker 只读）
_groups = []
_groups_lock = threading.Lock()
_self_open_id = ""
_self_chat = {}

# AI 自己刚发出的消息指纹（用于 self-loop 防护：AI 发的 @自己 消息不做处理）
_self_sent = deque(maxlen=50)   # (ts, normalized_text)
_self_sent_lock = threading.Lock()


def log(msg: str):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def run_cmd(args, timeout=60):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


# ---------------- 配置 ----------------

def normalize_group(g: dict) -> dict:
    return {
        "id": (g.get("id") or "").strip(),
        "name": (g.get("name") or "").strip(),
        "at_trigger": bool(g.get("at_trigger", True)),
        "keywords": [str(k).strip() for k in (g.get("keywords") or []) if str(k).strip()],
        "reply_mode": g.get("reply_mode", "group"),
        "history_size": int(g.get("history_size", DEFAULT_HISTORY_SIZE)),
        "free_response": bool(g.get("free_response", False)),
    }


def load_config():
    """返回 (self_open_id, self_chat, groups)。"""
    data = {}
    if CONFIG_PATH.exists():
        try:
            data = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8")) or {}
        except Exception as e:
            log(f"配置文件解析失败: {e}")
            return "", {}, []
    self_open_id = (data.get("self_open_id") or "").strip()
    sc = data.get("self_chat") or {}
    self_chat = {
        "enabled": bool(sc.get("enabled", False)),
        "conversation_id": (sc.get("conversation_id") or "").strip(),
        "history_size": int(sc.get("history_size", 20)),
    }
    groups = [normalize_group(g) for g in (data.get("groups") or [])]
    return self_open_id, self_chat, [g for g in groups if g["id"]]


def find_group(groups: list, conv_id: str):
    for g in groups:
        if g["id"] == conv_id:
            return g
    return None


_ECHO_TTL = 300  # 回显通常在 1~2 秒内到达，5 分钟窗口足够


def normalize_content(s: str) -> str:
    """归一化消息正文：去掉 @ 提及（<@id> 或开头 @名字）和多余空白，用于回显比对。"""
    t = s or ""
    t = re.sub(r"<@[^>]*>", "", t)          # 去所有 <@openDingTalkId> 占位符
    t = re.sub(r"^\s*@\S+\s*", "", t)       # 去开头 "@名字" 形式
    return re.sub(r"\s+", " ", t).strip()


def record_self_sent(text: str):
    norm = normalize_content(text)
    if not norm:
        return
    with _self_sent_lock:
        _self_sent.append((time.time(), norm))
        while _self_sent and _self_sent[0][0] < time.time() - _ECHO_TTL:
            _self_sent.popleft()


def is_self_sent(content: str) -> bool:
    norm = normalize_content(content)
    if not norm:
        return False
    now = time.time()
    with _self_sent_lock:
        for ts, txt in _self_sent:
            if not txt or (now - ts) >= _ECHO_TTL:
                continue
            if norm == txt:
                return True
            # 回显可能带额外 @ 前缀/后缀，用较长文本的子串匹配兜底
            if len(txt) >= 10 and txt in norm:
                return True
    return False


# ---------------- 消息缓存（按群共享） ----------------

def load_history():
    global _history
    try:
        if HISTORY_PATH.exists():
            raw = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
            _history = {}
            for conv_id, val in raw.items():
                if isinstance(val, dict):
                    # 兼容旧结构 {conv_id: {sender_id: [msgs]}}，合并为群级
                    merged = []
                    for msgs in val.values():
                        merged.extend(msgs)
                    _history[conv_id] = deque(merged[-HISTORY_CAP:],
                                              maxlen=HISTORY_CAP)
                else:
                    _history[conv_id] = deque(val[-HISTORY_CAP:],
                                              maxlen=HISTORY_CAP)
    except Exception as e:
        log(f"历史缓存加载失败（忽略）: {e}")
        _history = {}


def save_history():
    try:
        with _history_lock:
            data = {c: list(dq) for c, dq in _history.items()}
        HISTORY_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2),
                                encoding="utf-8")
    except Exception as e:
        log(f"历史缓存落盘失败: {e}")


def get_history(conv_id: str, size: int) -> list:
    with _history_lock:
        dq = _history.setdefault(conv_id, deque(maxlen=HISTORY_CAP))
        return list(dq)[-size:]


def append_history(conv_id: str, entry: dict):
    with _history_lock:
        dq = _history.setdefault(conv_id, deque(maxlen=HISTORY_CAP))
        dq.append(entry)


# ---------------- 认证 / 发送 ----------------

def check_auth() -> bool:
    try:
        r = run_cmd([DWS, "auth", "status", "--format", "json"], 30)
        data = json.loads(r.stdout or "{}")
        if data.get("authenticated"):
            log(f"认证正常: corp={data.get('corp_name')} "
                f"refresh到期={data.get('refresh_expires_at')}")
            return True
        log(f"认证失败: {(r.stdout or '')[:200]}{(r.stderr or '')[:200]}")
    except Exception as e:
        log(f"认证检查异常: {e}")
    return False


def send_reply(ev: dict, group: dict, text: str) -> bool:
    conv_id = ev.get("conversation_id") or ""
    sender_name = ev.get("sender") or ""
    sender_id = ev.get("sender_open_dingtalk_id") or ""
    reply_mode = group.get("reply_mode", "group")

    if reply_mode == "dm" and sender_id:
        cmd = [DWS, "chat", "+messages-send", "--as", "user",
               "--open-dingtalk-id", sender_id, "--markdown", text, "-y"]
        target_desc = f"私聊 {sender_name}"
        want_at = False
    else:
        want_at = AT_SENDER and bool(sender_id) and not group.get("free_response")
        base_cmd = [DWS, "chat", "+messages-send", "--as", "user",
                    "--chat-id", conv_id, "--markdown", text, "-y"]
        if want_at:
            at_markdown = f"<@{sender_id}> {text}"
            cmd = [DWS, "chat", "+messages-send", "--as", "user",
                   "--chat-id", conv_id, "--markdown", at_markdown,
                   "--at-open-dingtalk-ids", sender_id, "-y"]
        else:
            cmd = base_cmd
        target_desc = f"群 {group.get('name') or conv_id}"

    # 带 @ 优先，失败回退不带 @（保证回复一定送达）
    if want_at:
        try:
            r = run_cmd(cmd, 60)
            if r.returncode == 0:
                log(f"回复成功(@{sender_name}) → {target_desc}: {text[:60]}")
                return True
            log(f"带 @ 发送失败，回退不带 @: {(r.stderr or '')[:150]}")
        except Exception as e:
            log(f"带 @ 发送异常，回退不带 @: {e}")
        cmd = base_cmd

    try:
        r = run_cmd(cmd, 60)
        if r.returncode == 0:
            log(f"回复成功 → {target_desc}: {text[:60]}")
            return True
        log(f"回复失败 → {target_desc}: {(r.stdout or '')[:200]} {(r.stderr or '')[:200]}")
        return False
    except Exception as e:
        log(f"回复异常 → {target_desc}: {e}")
        return False


# ---------------- 关键词 / prompt ----------------


def send_self_reply(conv_id: str, text: str) -> bool:
    """回复到「我」会话（自己给自己发消息的单聊）。"""
    cmd = [DWS, "chat", "+messages-send", "--as", "user",
           "--chat-id", conv_id, "--markdown", text, "-y"]
    try:
        r = run_cmd(cmd, 60)
        if r.returncode == 0:
            log(f"回复成功 → 我: {text[:60]}")
            return True
        log(f"回复失败 → 我: {(r.stdout or '')[:200]} {(r.stderr or '')[:200]}")
        return False
    except Exception as e:
        log(f"回复异常 → 我: {e}")
        return False

def match_keyword(content: str, keywords: list):
    for kw in keywords:
        if kw and kw in content:
            return kw
    return None


def build_prompt(group: dict, sender: str, content: str, hist: list) -> str:
    lines = []
    if hist:
        lines.append("你在钉钉群里，以下是最近对话历史（供理解上下文，不要重复历史内容）：")
        for m in hist:
            who = "你" if m.get("role") == "assistant" else m.get("sender", "?")
            lines.append(f"{who}: {m.get('content', '')}")
        lines.append("")

    lines.append(f"{sender} 在钉钉群「{group.get('name', '')}」里发来消息：")
    lines.append(content)
    lines.append("")
    lines.append(
        "请以你的身份直接回复对方，输出要发回群里的正文（纯中文，简洁明了）。"
        "结合对话历史回答；提问就准确回答，任务请求就执行并汇报结果。"
        "不要输出解释性前缀，直接给正文；可用简单列表和加粗，不要用代码块。"
    )
    return "\n".join(lines)


def call_hermes(prompt: str) -> str:
    try:
        r = run_cmd([HERMES, "chat", "-q", prompt, "-Q", "--max-turns", "20"],
                    HERMES_TIMEOUT)
        lines = (r.stdout or "").splitlines()
        reply = "\n".join(
            ln for ln in lines if ln.strip() and not ln.startswith("session_id:")
        ).strip()
        if r.returncode != 0 and not reply:
            reply = f"（处理失败，退出码 {r.returncode}）"
        return reply
    except subprocess.TimeoutExpired:
        return "（处理超时，请稍后再试）"
    except Exception as e:
        return f"（处理异常：{e}）"


# ---------------- 事件处理 ----------------

_seen = set()
_seen_lock = threading.Lock()


def process_message(groups: list, self_chat: dict, self_open_id: str,
                    ev: dict, source: str):
    conv_id = ev.get("conversation_id") or ""
    sender = ev.get("sender") or ""
    sender_id = ev.get("sender_open_dingtalk_id") or ""
    content = ev.get("content") or ""
    msg_id = ev.get("event_id") or ev.get("message_id") or ""

    # self-loop 防护：AI 自己刚发的回复回显回来，所有来源都忽略
    if is_self_sent(content):
        log(f"忽略 AI 自发消息回显 [{source}]: {content[:80]}")
        return

    # 确定会话配置
    if source == "self":
        # 「我」会话：只处理本人会话的消息，每条都触发（一问一答）
        if not (self_chat.get("enabled")
                and conv_id == self_chat.get("conversation_id")):
            return  # 不是「我」会话的消息，忽略
        group = {"name": "我", "history_size": self_chat.get("history_size", 20)}
        is_self = True
    else:
        group = find_group(groups, conv_id)
        if not group:
            log(f"忽略非白名单群 {conv_id} 的消息 from={sender}")
            return
        # @ 触发只响应本人（配置了 self_open_id 才生效，其他人 @ 忽略）
        if source == "at" and self_open_id:
            if sender_id != self_open_id:
                log(f"忽略非本人 @ 消息 from={sender}({sender_id})")
                return
        # 自由响应群已由 group 订阅处理，@ 时不重复触发
        if source == "at" and group.get("free_response"):
            return
        # group 来源触发判定：自由响应群直接处理，否则按关键词精筛
        if source == "group":
            if group.get("free_response"):
                log(f"自由响应 群[{group['name']}] from={sender}: {content[:100]}")
            else:
                kw = match_keyword(content, group["keywords"])
                if not kw:
                    return  # 未命中关键词，静默丢弃
                log(f"关键词命中 [{kw}] 群[{group['name']}] from={sender}: {content[:100]}")
        is_self = False

    # 去重
    if msg_id:
        with _seen_lock:
            if msg_id in _seen:
                return
            _seen.add(msg_id)
            if len(_seen) > 50000:
                _seen.clear()

    hist = get_history(conv_id, group["history_size"])
    prompt = build_prompt(group, sender, content, hist)
    log(f"处理[{source}] from={sender} conv={conv_id} 上下文{len(hist)}条")

    reply = call_hermes(prompt)
    if not reply:
        reply = "（已收到，但未生成回复内容）"
    if len(reply) > MAX_REPLY_LEN:
        reply = reply[:MAX_REPLY_LEN] + "\n…（内容过长已截断）"

    if is_self:
        ok = send_self_reply(conv_id, reply)
    else:
        ok = send_reply(ev, group, reply)
    if ok:
        record_self_sent(reply)

    # 更新缓存（用户消息 + 回复）
    ts = int(time.time())
    append_history(conv_id, {
        "sender": sender, "content": content, "role": "user", "ts": ts})
    append_history(conv_id, {
        "sender": "assistant", "content": reply, "role": "assistant", "ts": ts})
    save_history()


# ---------------- 订阅子进程管理 ----------------

def stderr_reader(proc):
    try:
        for line in proc.stderr:
            s = line.strip()
            if s:
                log(f"[dws] {s[:200]}")
    except Exception:
        pass


def stdout_reader(proc, source: str, restart_event: threading.Event):
    """读 stdout 事件流入队；EOF(子进程退出)时触发 restart_event。"""
    try:
        for line in proc.stdout:
            if _shutdown.is_set():
                break
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if isinstance(ev, dict) and (ev.get("content") is not None
                                             or ev.get("conversation_id")):
                    _event_queue.put((source, ev))
            except json.JSONDecodeError:
                log(f"非 JSON 输出: {line[:120]}")
    except Exception as e:
        log(f"stdout 读取异常({source}): {e}")
    finally:
        restart_event.set()


def launch_subscription(source: str, cmd: list, restart_event: threading.Event):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1)
    with _procs_lock:
        _procs.append(proc)
    threading.Thread(target=stderr_reader, args=(proc,), daemon=True).start()
    threading.Thread(target=stdout_reader, args=(proc, source, restart_event),
                     daemon=True).start()
    log(f"启动订阅 [{source}]: {' '.join(cmd[2:])}")
    return proc


def stop_all_subscriptions():
    with _procs_lock:
        procs = list(_procs)
        _procs.clear()
    for p in procs:
        if p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass
    for p in procs:
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                p.kill()
            except Exception:
                pass


def worker():
    """从队列取事件，串行处理。"""
    while not _shutdown.is_set():
        try:
            source, ev = _event_queue.get(timeout=1)
        except queue.Empty:
            continue
        try:
            with _groups_lock:
                groups = list(_groups)
                self_open_id = _self_open_id
                self_chat = _self_chat
            process_message(groups, self_chat, self_open_id, ev, source)
        except Exception as e:
            log(f"事件处理异常: {e}")


# ---------------- 主循环 ----------------

def run_forever():
    global _groups, _self_open_id, _self_chat

    while not _shutdown.is_set():
        self_open_id, self_chat, groups = load_config()
        with _groups_lock:
            _groups = groups
            _self_open_id = self_open_id
            _self_chat = self_chat

        if not groups and not self_chat.get("enabled"):
            log("配置 groups 为空且 self_chat 未启用，不启动订阅，30 秒后重检")
            if _shutdown.wait(30):
                break
            continue

        log(f"加载配置：{len(groups)} 个群")
        for g in groups:
            log(f"  群[{g['name']}] at={g['at_trigger']} "
                f"keywords={g['keywords']} reply={g['reply_mode']} "
                f"hist={g['history_size']}")
        if self_chat.get("enabled"):
            log(f"  self_chat=启用 conv={self_chat.get('conversation_id')} "
                f"hist={self_chat.get('history_size')}")

        if not check_auth():
            log("认证失败，60 秒后重试")
            if _shutdown.wait(60):
                break
            continue

        restart_event = threading.Event()

        # 1. self chat 订阅（「我」会话一问一答）
        if self_chat.get("enabled") and self_chat.get("conversation_id") \
                and self_open_id:
            launch_subscription(
                "self", [DWS, "event", "+listen-im", "--kind", "sender",
                         "--open-dingtalk-id", self_open_id,
                         "--events", "message"], restart_event)

        # 2. at-me 订阅（任一白名单群启用 @ 触发）
        if any(g["at_trigger"] for g in groups):
            launch_subscription(
                "at", [DWS, "event", "+listen-im", "--kind", "at-me",
                       "--events", "message"], restart_event)

        # 3. 每个配了 keywords 或 free_response 的群一个 group 订阅
        for g in groups:
            if g["keywords"] or g["free_response"]:
                launch_subscription(
                    "group", [DWS, "event", "+listen-im", "--kind", "group",
                              "--chat-id", g["id"], "--events", "message"],
                    restart_event)

        # 等任一订阅退出 → 重启全部
        restart_event.wait()
        stop_all_subscriptions()

        if _shutdown.is_set():
            break
        log("订阅退出，3 秒后重启")
        if _shutdown.wait(3):
            break


def _handle_signal(sig, frame):
    log(f"收到信号 {sig}，准备干净退出")
    _shutdown.set()
    stop_all_subscriptions()
    save_history()


def main():
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    log("=" * 50)
    log("钉钉群桥接守护进程启动（群级策略 + 多轮上下文）")
    load_history()

    threading.Thread(target=worker, daemon=True).start()
    run_forever()
    log("已退出")


if __name__ == "__main__":
    main()
