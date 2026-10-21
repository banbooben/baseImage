#!/usr/bin/env bash
# dedup-dsh-packages.sh
#
# 消除 dsh 运行时(npx cache)与 profile 插件(web/node_modules)之间的
# @deepseek-ai/* 双副本问题。
#
# 根因:dsh 运行时与 profile 插件各自安装了一份相同版本(0.2.1-alpha.2)的
# @deepseek-ai/* 包。其中 dsh-tools 里的 TOOL_RUNTIME_SCHEDULER 是 Symbol,
# 两份副本各自实例化得到不相等的 Symbol,跨副本查找工具调度器时
# ctx.tools[TOOL_RUNTIME_SCHEDULER] === undefined,调用 .prepare() 崩溃:
#   Cannot read properties of undefined (reading 'prepare')
#
# 修复:让 profile 侧的重叠包复用运行时那份(单副本)。
# 注意:profile 跑 pnpm install(nodeLinker=hoisted)会重新 hoist 真目录、
# 覆盖 symlink,需在 install 之后重新执行本脚本。
#
# 用法:
#   dedup-dsh-packages.sh          # 去重所有重叠包(推荐)
#   dedup-dsh-packages.sh --dsh-tools-only   # 只去重 dsh-tools(最小修复)
#
# 可用环境变量覆盖(镜像构建时用):
#   DSH_RUNTIME_NM   dsh 运行时 node_modules 根目录
#   DSH_PROFILE_NM   profile web 的 node_modules 根目录
set -euo pipefail

SCOPE="${1:---all}"
RUNTIME_NM="${DSH_RUNTIME_NM:-}"
PROFILE_NM="${DSH_PROFILE_NM:-$HOME/.dsh/profiles/web/node_modules}"

# ---- 自动发现 dsh 运行时 ----
discover_runtime() {
  local launcher="$HOME/.local/bin/dsh"
  [ -f "$launcher" ] || return 1
  local bin_line
  bin_line="$(grep -m1 '^BIN=' "$launcher" 2>/dev/null | sed -E 's/^BIN="([^"]+)".*/\1/' || true)"
  [ -n "$bin_line" ] || return 1
  # bin_line 形如 .../node_modules/@deepseek-ai/dsh/lib/bin.js
  RUNTIME_NM="${bin_line%/@deepseek-ai/dsh/lib/bin.js}"
  [ -d "$RUNTIME_NM/@deepseek-ai/dsh-tools" ] && return 0
  return 1
}

if [ -z "$RUNTIME_NM" ]; then
  if ! discover_runtime; then
    echo "ERROR: 无法定位 dsh 运行时 node_modules。" >&2
    echo "       请设置 DSH_RUNTIME_NM 指向含 @deepseek-ai/dsh-tools 的 node_modules 目录。" >&2
    exit 1
  fi
fi

RUNTIME_DS="$RUNTIME_NM/@deepseek-ai"
PROFILE_DS="$PROFILE_NM/@deepseek-ai"

if [ ! -d "$RUNTIME_DS" ]; then
  echo "ERROR: 运行时 @deepseek-ai 目录不存在: $RUNTIME_DS" >&2
  exit 1
fi
if [ ! -d "$PROFILE_DS" ]; then
  echo "ERROR: profile @deepseek-ai 目录不存在: $PROFILE_DS" >&2
  exit 1
fi

ver() { python3 -c "import json;print(json.load(open('$1/package.json'))['version'])" 2>/dev/null || echo ''; }

linked=0; skipped=0; mismatched=0
for pkgdir in "$PROFILE_DS"/*/; do
  name="$(basename "$pkgdir")"
  case "$name" in
    *.orig.bak|*.orig.bak.*) continue ;;  # 跳过历史备份
  esac
  [ -d "$RUNTIME_DS/$name" ] || continue    # 只处理两边都存在的重叠包
  [ "$SCOPE" = "--dsh-tools-only" ] && [ "$name" != "dsh-tools" ] && continue

  wv="$(ver "$PROFILE_DS/$name")"
  nv="$(ver "$RUNTIME_DS/$name")"
  if [ "$wv" != "$nv" ]; then
    echo "SKIP  $name  版本不一致 web=$wv npx=$nv"
    mismatched=$((mismatched+1))
    continue
  fi

  target="$PROFILE_DS/$name"
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$RUNTIME_DS/$name")" ]; then
    echo "OK    $name  (已是单副本 symlink)"
    skipped=$((skipped+1))
    continue
  fi

  if [ -L "$target" ]; then rm "$target"; fi
  if [ -e "$target" ]; then mv "$target" "$target.orig.bak.$(date +%s)"; fi
  ln -s "$RUNTIME_DS/$name" "$target"
  echo "LINK  $name  ->  $RUNTIME_DS/$name"
  linked=$((linked+1))
done

echo
echo "完成: symlink $linked 个, 已正确 $skipped 个, 版本不一致跳过 $mismatched 个。"
