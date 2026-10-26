# dsh @deepseek-ai 双副本问题修复文档

> 适用场景:dsh 接入 DingTalk 群聊后,群消息能收到、模型能理解、也调了工具,
> 但工具一执行就崩溃,群里永远没有回复。
>
> 结论:不是插件版本问题(升级救不了),是 dsh 运行时与 profile 插件各自装了
> 一份相同的 @deepseek-ai 包,其中 dsh-tools 的 Symbol 跨副本不匹配导致崩溃。

---

## 一、问题现象

群里发消息后机器人无回复。查看协调器会话,每次工具调用都崩溃:

```
Cannot read properties of undefined (reading 'prepare')
code: UNKNOWN
```

协调请求在重试 3 次后状态变为 `exhausted`,错误为
`topic_request_retry_exhausted:<id>`,消息终态 `decision-failed`。

## 二、根因

dsh 采用「运行时 + profile 插件」两套 node_modules 树:

| 树 | 路径(本机示例) | 内容 |
|---|---|---|
| 运行时 | `~/.npm/_npx/<hash>/node_modules` | dsh 核心,约 300 个 @deepseek-ai 包 |
| profile 插件 | `~/.dsh/profiles/web/node_modules` | dingtalk-dsh-assistant 及其依赖,24 个 @deepseek-ai 包 |

两套树里有 **24 个完全同名同版本**的 @deepseek-ai 包(版本均为
`0.2.1-alpha.2`,外加 cosmokit 1.8.6 / schemastery 3.18.5 /
node-addon-system 0.1.2),但物理上是两份独立文件。

其中 `@deepseek-ai/dsh-tools` 内部定义了一个全局唯一的键:

```js
const TOOL_RUNTIME_SCHEDULER = Symbol("@deepseek-ai/dsh-tools.scheduler");
```

`Symbol()` 每次执行都返回一个新实例(即使描述字符串相同)。两份副本各自
实例化一次,得到两个不相等的 Symbol。协调器子 agent 用「A 副本」的 Symbol
当 key 去查「B 副本」注册的工具调度器:

```js
// dsh-agent-loop/lib/index.js:582
const prepared = await ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(call.exec);
```

`ctx.tools[TOOL_RUNTIME_SCHEDULER]` 查不到 → `undefined` → 调 `.prepare()`
即报 `Cannot read properties of undefined (reading 'prepare')`。

## 三、修复原理

消除双副本:让 profile 侧的 24 个重叠包用 symlink 复用运行时的那份,
保证模块实例唯一、Symbol 一致。因为两边版本完全相同,直接指向运行时副本
是安全的。

（`dsh-tools` 是当前已暴露崩溃的最小修复点；其余 23 个重叠包也存在同样的
类身份 / instanceof / Symbol 隐患,建议一并去重。）

## 四、修复脚本

脚本文件:`~/.dsh/dedup-dsh-packages.sh`(幂等,可重复执行)

```bash
#!/usr/bin/env bash
# 用法:
#   dedup-dsh-packages.sh            # 去重所有重叠包(推荐)
#   dedup-dsh-packages.sh --dsh-tools-only   # 只去重 dsh-tools(最小修复)
# 环境变量覆盖(镜像构建时用):
#   DSH_RUNTIME_NM   dsh 运行时 node_modules 根目录
#   DSH_PROFILE_NM   profile web 的 node_modules 根目录
set -euo pipefail

SCOPE="${1:---all}"
RUNTIME_NM="${DSH_RUNTIME_NM:-}"
PROFILE_NM="${DSH_PROFILE_NM:-$HOME/.dsh/profiles/web/node_modules}"

# 自动发现运行时:从 ~/.local/bin/dsh launcher 的 BIN= 行反推 node_modules
discover_runtime() {
  local launcher="$HOME/.local/bin/dsh"
  [ -f "$launcher" ] || return 1
  local bin_line
  bin_line="$(grep -m1 '^BIN=' "$launcher" 2>/dev/null | sed -E 's/^BIN="([^"]+)".*/\1/' || true)"
  [ -n "$bin_line" ] || return 1
  RUNTIME_NM="${bin_line%/@deepseek-ai/dsh/lib/bin.js}"
  [ -d "$RUNTIME_NM/@deepseek-ai/dsh-tools" ] && return 0
  return 1
}

if [ -z "$RUNTIME_NM" ]; then
  if ! discover_runtime; then
    echo "ERROR: 无法定位 dsh 运行时 node_modules。" >&2
    echo "       请设置 DSH_RUNTIME_NM 指向含 @deepseek-ai/dsh-tools 的目录。" >&2
    exit 1
  fi
fi

RUNTIME_DS="$RUNTIME_NM/@deepseek-ai"
PROFILE_DS="$PROFILE_NM/@deepseek-ai"
[ -d "$RUNTIME_DS" ] || { echo "ERROR: $RUNTIME_DS 不存在" >&2; exit 1; }
[ -d "$PROFILE_DS" ] || { echo "ERROR: $PROFILE_DS 不存在" >&2; exit 1; }

ver() { python3 -c "import json;print(json.load(open('$1/package.json'))['version'])" 2>/dev/null || echo ''; }

linked=0; skipped=0; mismatched=0
for pkgdir in "$PROFILE_DS"/*/; do
  name="$(basename "$pkgdir")"
  case "$name" in *.orig.bak|*.orig.bak.*) continue;; esac
  [ -d "$RUNTIME_DS/$name" ] || continue
  [ "$SCOPE" = "--dsh-tools-only" ] && [ "$name" != "dsh-tools" ] && continue

  wv="$(ver "$PROFILE_DS/$name")"; nv="$(ver "$RUNTIME_DS/$name")"
  if [ "$wv" != "$nv" ]; then
    echo "SKIP  $name  版本不一致 web=$wv npx=$nv"; mismatched=$((mismatched+1)); continue
  fi

  target="$PROFILE_DS/$name"
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$RUNTIME_DS/$name")" ]; then
    echo "OK    $name  (已是单副本 symlink)"; skipped=$((skipped+1)); continue
  fi
  [ -L "$target" ] && rm "$target"
  [ -e "$target" ] && mv "$target" "$target.orig.bak.$(date +%s)"
  ln -s "$RUNTIME_DS/$name" "$target"
  echo "LINK  $name  ->  $RUNTIME_DS/$name"; linked=$((linked+1))
done

echo; echo "完成: symlink $linked 个, 已正确 $skipped 个, 版本不一致跳过 $mismatched 个。"
```

## 五、镜像构建脚本集成

原则:**在 `pnpm install`(或等价步骤)之后、服务启动之前**执行去重脚本,
把 symlink 固化进镜像层。

### 5.1 运行时是全局安装

若镜像里用 `npm i -g @deepseek-ai/dsh@0.2.1-alpha.2` 装运行时,
运行时 node_modules = `$(npm root -g)`。

```dockerfile
# ... 安装 dsh 运行时 + profile 依赖 ...
RUN pnpm install --dir /app/profiles/web

# 消除 @deepseek-ai 双副本(必须在 pnpm install 之后)
COPY dedup-dsh-packages.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/dedup-dsh-packages.sh && \
    DSH_RUNTIME_NM="$(npm root -g)" \
    DSH_PROFILE_NM="/app/profiles/web/node_modules" \
    /usr/local/bin/dedup-dsh-packages.sh --all
```

### 5.2 运行时是 npx 缓存

若镜像里用 `npx @deepseek-ai/dsh@0.2.1-alpha.2` 拉取运行时(npx 缓存 hash 不固定),
先定位缓存目录,再传 `DSH_RUNTIME_NM`:

```dockerfile
RUN pnpm install --dir /app/profiles/web

# 定位 npx 缓存中的运行时 node_modules
RUN RUNTIME_NM="$(find "$HOME/.npm/_npx" -type d -path '*/node_modules/@deepseek-ai/dsh-tools' 2>/dev/null | head -1 | sed 's#/node_modules/@deepseek-ai/dsh-tools$##')" && \
    [ -n "$RUNTIME_NM" ] || { echo 'dsh runtime not found' >&2; exit 1; } && \
    DSH_RUNTIME_NM="$RUNTIME_NM" \
    DSH_PROFILE_NM="/app/profiles/web/node_modules" \
    /usr/local/bin/dedup-dsh-packages.sh --all
```

### 5.3 运行时兜底(可选,双保险)

为防止镜像启动后有人再跑 `pnpm install` 把 symlink 冲掉,可在容器 entrypoint
或 systemd `ExecStartPre` 里再执行一次去重脚本(幂等,已正确的会被跳过):

```ini
[Service]
ExecStartPre=/usr/local/bin/dedup-dsh-packages.sh --all
ExecStart=/usr/local/bin/dsh web
```

## 六、验证清单

构建 / 修复后按以下顺序确认:

1. **单副本确认**:profile 侧 24 个重叠包都是 symlink 且指向运行时:
   ```bash
   ls -l "$DSH_PROFILE_NM/@deepseek-ai/" | grep -c -- '->'
   # 期望:24(与两边重叠包总数一致)
   readlink -f "$DSH_PROFILE_NM/@deepseek-ai/dsh-tools/lib/index.js"
   # 期望:解析到运行时目录
   ```

2. **服务健康**:
   ```bash
   curl -s http://127.0.0.1:18998/health
   # 期望:"status":"ok","dwsBridge":{"healthy":true}
   ```

3. **端到端**:向测试群发一条消息,观察协调请求状态从 `pending` 变为
   `completed`(而不是 `exhausted`),并在数据库出现 `kind=topic-reply` 的
   outbound 记录:
   ```bash
   sqlite3 ~/.dsh/task-sessions.sqlite \
     "SELECT count(*) FROM dynamic_notifications WHERE json_extract(body,'$.kind')='topic-reply';"
   # 期望:数值递增,且 payload.text 为符合上下文的实质回复
   ```

## 七、注意事项

1. **必须放在 pnpm install 之后**:`nodeLinker: hoisted` 会在 install 时重新
   hoist 真目录、覆盖 symlink。任何一次 install 后都要重跑去重脚本。
2. **版本一致性是前提**:脚本会校验两边版本,不一致的包会跳过(不 symlink)。
   若未来 dsh 运行时与 dingtalk 插件锁定到不同版本,需先解决版本对齐,
   否则跳过会导致问题保留。
3. **native addon 架构**:`node-addon-system` / `node-addon-system-linux-x64`
   是原生二进制包。跨架构构建镜像(如 x86 构建、ARM 运行)时需确保运行时
   副本的目标架构与运行环境一致,否则不要对这两个包做 symlink。
4. **运行时路径不固定**:npx 缓存 hash、全局 npm 前缀随环境变化,务必用
   `DSH_RUNTIME_NM` 显式传入,不要硬编码路径。
5. **上游根治建议**:该问题的真正解法是让 dingtalk-dsh-assistant 把
   `@deepseek-ai/*` 声明为 peerDependency(由运行时提供),而非自带一份依赖。
   本方案是绕过上游架构问题的确定性兜底,建议同步反馈给插件维护方。
