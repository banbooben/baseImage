#!/bin/bash
# CI 版本解析的单一实现（GitHub Actions 与 GitLab CI 共用）。
#
#   resolve_versions.sh python <series> <fallback> [--prerelease]
#   resolve_versions.sh java   <major>  <fallback>
#   resolve_versions.sh redis  <series> <fallback>
#
# stdout 只打印解析结果（解析失败时打印 fallback），日志走 stderr，
# 便于 VERSION=$(ci/resolve_versions.sh ...) 捕获。解析失败不致命。
set -u

kind="${1:?usage: resolve_versions.sh <python|java|redis> <series> <fallback> [--prerelease]}"
series="${2:?series/major is required}"
fallback="${3:?fallback is required}"
prerelease="${4:-}"

resolve_endoflife(){ # $1=product $2=series → 打印 latest 版本（可能为空）
  curl -fsSL "https://endoflife.date/api/$1/$2.json" 2>/dev/null \
    | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

version=""
case "$kind" in
  python)
    version="$(resolve_endoflife python "$series")"
    # 正式版发布前 endoflife 无数据：以 ftp 目录内真实存在的 tar 包名为准解析
    # （预发布包放在 X.Y.0/ 目录里）
    if [ -z "$version" ] && [ "$prerelease" = "--prerelease" ]; then
      escaped="${series//./\\.}"
      version="$(curl -fsSL "https://www.python.org/ftp/python/${series}.0/" 2>/dev/null \
        | grep -oE "Python-${escaped}\.[0-9]+((a|b|rc)[0-9]+)?\.tar\.xz" \
        | sed 's/^Python-//; s/\.tar\.xz$//' | sort -Vu | tail -n 1)"
    fi
    ;;
  java)
    next=$((series + 1))
    version="$(curl -fsSL "https://api.adoptium.net/v3/info/release_versions?version=%5B${series}%2C${next}%29&release_type=ga&page_size=1&sort_method=DATE&sort_order=DESC" 2>/dev/null \
      | sed -n 's/.*"openjdk_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    version="${version%-LTS}"
    ;;
  redis)
    version="$(resolve_endoflife redis "$series")"
    ;;
  *)
    echo "unknown kind: $kind (expect python|java|redis)" >&2
    exit 2
    ;;
esac

if [ -z "$version" ]; then
  echo "Failed to resolve $kind $series, using fallback" >&2
  version="$fallback"
fi
echo "Resolved $kind version: $version (series $series)" >&2
echo "$version"
