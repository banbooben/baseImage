#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 DBeaver 自带驱动定义里的 Maven 依赖预取到 DBeaver 的 maven 缓存目录。

路径与 DBeaver 源码保持一致（见 MavenRepository.getLocalCacheDir /
MavenArtifactVersion.getCacheFile）：

    <DBEAVER_DATA>/DBeaverData/drivers/maven/<repoId>/<groupId 原样>/
        <artifactId>-<version>[-<classifier>].<jar|pom>

版本号直接读当前安装的 DBeaver 的 plugin.xml 驱动定义，所以和 DBeaver 运行期
真正请求的版本一致（这是之前手工钉版本号失败的根本原因）：

    maven:/g:a:RELEASE[x]  -> 固定 x
    maven:/g:a:RELEASE     -> 构建时从 Maven 元数据取最新 release

POM 依赖按 DBeaver 的规则递归解析：默认只取 compile/runtime；驱动定义带
load-optional-dependencies 时额外取 optional 与 provided。父 POM、祖父 POM、
BOM（scope=import）的 dependencyManagement 也一并处理，否则运行期
loadPOM() 会去访问网络。

除了 maven: 坐标，还处理驱动定义里的 http(s):// 直链（如 GaussDB 的 gsjdbc4、
H2/DuckDB/SQL Server 等定义里的 license 文本），按 DriverLibraryRemote 的规则存到：

    <driversHome>/remote/<URL 的 path>

license 属于附属文件：DBeaver 校验收不到会弹空的下载框，所以同样要预取并记录。
它的来源多是 raw.githubusercontent.com，部分网络不可达——这类文件用短超时、
失败后在 drivers.xml 里把该库标记 disabled="true"，既不阻塞构建也不影响连接。

repo: / drivers/... 这类需要安装包或内置 bundle 的库仍然跳过。

另外会预置 DBeaver CE 自身没有的自定义驱动（目前是 Redis，见 CUSTOM_DRIVERS）：
下载自包含的 JDBC 包到 remote/，并生成 drivers.xml 给 install_dbeaver.sh。

生成的 drivers.xml 不只放自定义驱动，还为每个白名单驱动补上已预取库的
<file> 记录。这一步是离线可用的关键：DBeaver 运行期判断"驱动文件是否齐全"
只看 drivers.xml 里记录的 resolved files（DriverLoaderDescriptor.resolvedFiles），
不会去扫描 maven/remote 缓存目录；没有 <file> 记录时即使 jar 就在缓存里，
首次连接仍会弹"下载驱动文件"。路径写成 ${drivers_home}/...，DBeaver 解析
drivers.xml 时会用 DriverDescriptor.getCustomDriversHome() 展开（与它自己
保存配置的格式一致）。

可用环境变量覆盖：
    DBEAVER_PLUGINS             驱动定义所在目录
    DBEAVER_DRIVER_CACHE        缓存根目录（默认 .../maven/aliyun）
    DBEAVER_DRIVERS_HOME        驱动根目录（默认缓存目录往上两级；remote/ 在其下）
    DBEAVER_CUSTOM_DRIVERS_OUT  生成的 drivers.xml 路径（不设则不生成）
    DBEAVER_DRIVER_IDS          逗号分隔的 driver id 白名单
    MAVEN_CENTRAL_PRIMARY       首选仓库（默认阿里云 central）
    MAVEN_CENTRAL_FALLBACK      备用仓库（默认 repo1）
    DBEAVER_DRIVER_JOBS         并发下载数（默认 8）
"""
import concurrent.futures
import os
import re
import shutil
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

PLUGINS = os.environ.get("DBEAVER_PLUGINS", "/deployment/software/dbeaver/plugins")
CACHE = os.environ.get("DBEAVER_DRIVER_CACHE",
                       "/deployment/software/dbeaver/data/DBeaverData/drivers/maven/aliyun")
# 驱动根目录：<data>/DBeaverData/drivers。maven 缓存和 remote 直链缓存都在它下面
DRIVERS_HOME = os.environ.get("DBEAVER_DRIVERS_HOME") or os.path.dirname(os.path.dirname(CACHE))
REMOTE_ROOT = os.path.join(DRIVERS_HOME, "remote")
REPOS = [u for u in (
    os.environ.get("MAVEN_CENTRAL_PRIMARY", "https://maven.aliyun.com/repository/central"),
    os.environ.get("MAVEN_CENTRAL_FALLBACK", "https://repo1.maven.org/maven2"),
) if u]
REPOS = [u.rstrip("/") + "/" for u in REPOS]
JOBS = int(os.environ.get("DBEAVER_DRIVER_JOBS", "8"))

# 常见的 Python 侧数据库 + 国产数据库。版本号来自 DBeaver 自己的驱动定义，
# 不在这里写死；需要增减时改 DBEAVER_DRIVER_IDS 或这个默认值。
DEFAULT_DRIVER_IDS = ",".join([
    "mysql8",                # MySQL 8
    "mariaDB",               # MariaDB
    "postgres-jdbc",         # PostgreSQL（含 PostGIS / waffle-jna 依赖）
    "oracle_thin",           # Oracle（ojdbc11 + orai18n + xdb6 + xmlparserv2）
    "microsoft",             # SQL Server
    "sqlite_jdbc",           # SQLite
    "h2_embedded_v3",        # H2（面向 Java/Python 测试）
    "h2_server",
    "com_clickhouse",        # ClickHouse（load-optional-dependencies）
    "starrocks",             # StarRocks
    "doris",                 # Apache Doris（复用 MySQL 驱动）
    "tidb",                  # TiDB（复用 MySQL 驱动）
    "iotdb",                 # Apache IoTDB
    "duckdb_jdbc",           # DuckDB
    "apache_hive4",          # Hive 4（standalone uber jar）
    # 其他常见（Python 侧常用）
    "db2",                   # IBM DB2（jcc）
    "snowflake_jdbc",        # Snowflake
    "greenplum-jdbc",        # Greenplum（复用 PostgreSQL + PostGIS）
    "jaybird",               # Firebird
    # 国产数据库
    "dameng",                # 达梦
    "kingbase-jdbc",         # 人大金仓
    "gbase8s",               # 南大通用 GBase 8s
    "alipay_oceanbase",      # OceanBase（MySQL 模式）
    "alipay_oceanbase_oracle",  # OceanBase（Oracle 模式）
    "yashandb",              # 崖山（定义里是 [LATEST]，构建时取最新）
    "gaussdb-jdbc",          # 华为 GaussDB / openGauss（华为云直链 gsjdbc4）
])
DRIVER_IDS = {s.strip() for s in
              (os.environ.get("DBEAVER_DRIVER_IDS") or DEFAULT_DRIVER_IDS).split(",") if s.strip()}

# DBeaver CE 本身不带 Redis 驱动（Redis 只在其付费版本里支持）。这里用社区 JDBC
# 驱动 dbVisitor 预置一个自定义驱动（provider=generic，即「Generic JDBC」），
# 由本脚本下载自包含的 -alone 包并生成 drivers.xml 片段。
#
# 用 http 直链而不是 maven 坐标的原因：
#   - -alone 包只有一个 jar，自包含 jedis/commons-pool2/gson，运行期不用解析依赖；
#   - 自定义驱动库的 ignore-dependencies 属性在 DBeaver 首次创建库时不生效，
#     用 maven 坐标会触发运行期依赖下载，离线环境下不可靠；
#   - 版本在构建时从 Maven 元数据取最新（满足“每次构建都用最新驱动”）。
CUSTOM_DRIVERS = [
    {
        "id": "redis-jedis",
        "name": "Redis",
        "class": "net.hasor.dbvisitor.driver.JdbcDriver",
        "url": "jdbc:dbvisitor:jedis://{host}:{port}?database={database}",
        "port": "6379",
        "database": "0",  # Redis 库编号，不是数据库名
        "description": "Redis via dbVisitor JDBC driver (community, not part of DBeaver CE)",
        "maven": ("net.hasor", "jdbc-redis", "alone"),
        # 阿里云/华为云镜像没有 -alone classifier，只有 Maven Central 有
        "artifact_url": "https://repo1.maven.org/maven2/net/hasor/jdbc-redis/{v}/jdbc-redis-{v}-alone.jar",
    },
]

# 平台专属的 classifier（如 DuckDB 的 windows_arm64），当前镜像用不到
SKIP_CLASSIFIERS = {"windows_arm64", "windows_x64", "macos_arm64", "macos_x64"}

_print_lock = threading.Lock()


def log(msg):
    with _print_lock:
        print(msg, flush=True)


# ---------------------------------------------------------------- HTTP

def http_get(url, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": "dbeaver-driver-prefetch/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def http_download(url, dest, timeout=180):
    req = urllib.request.Request(url, headers={"User-Agent": "dbeaver-driver-prefetch/1.0"})
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = "{}.{}.part".format(dest, uuid.uuid4().hex[:8])
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp, open(tmp, "wb") as out:
            shutil.copyfileobj(resp, out, 1024 * 256)
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


# ---------------------------------------------------------------- 远程直链库

def remote_cache_path(url):
    """与 DriverLibraryRemote.getLocalFilePath() 一致：
    DOWNLOAD_DIR + URI.getPath()，即 <drivers>/remote/<URL path>。"""
    path = urllib.parse.unquote(urllib.parse.urlsplit(url).path)
    return os.path.join(REMOTE_ROOT, path.lstrip("/"))


def fetch_remote(url, timeout=180, attempts=2):
    """下载 http(s) 直链库；返回 (ok, 来源描述)。"""
    dest = remote_cache_path(url)
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        return True, "cached"
    last_err = None
    for attempt in range(attempts):
        try:
            http_download(url, dest, timeout=timeout)
            return True, url
        except urllib.error.HTTPError as e:
            last_err = "{} -> HTTP {}".format(url, e.code)
            break
        except Exception as e:  # 网络抖动
            last_err = "{} -> {}".format(url, e)
            if attempt < attempts - 1:
                time.sleep(2)
    log("WARN 远程库下载失败: {}".format(last_err))
    return False, last_err


def _xml_quote(value):
    return escape(value, {'"': "&quot;"})


def _home_rel(path):
    rel = os.path.relpath(os.path.abspath(path), os.path.abspath(DRIVERS_HOME))
    return rel.replace(os.sep, "/")


def _file_attr(fid, path):
    """DBeaver 自己保存配置时用的格式：${drivers_home}/<相对路径>。"""
    return 'id="{}" path="${{drivers_home}}/{}"'.format(
        _xml_quote(fid), _xml_quote(_home_rel(path)))


def _maven_library_files(lib, maven_versions, resolver):
    """一个 maven 根库在 DBeaver resolvedFiles 里的全部文件（主 jar + 传递依赖）。"""
    key = (lib["group"], lib["artifact"], lib["classifier"])
    version = maven_versions.get(key)
    if not version:
        return []
    files = []
    for group, artifact, ver, ext, classifier in resolver.files_by_root.get(
            (lib["group"], lib["artifact"], version, lib["classifier"]), []):
        path = cache_path(group, artifact, ver, ext, classifier)
        if os.path.isfile(path):
            files.append(("{}:{}:{}".format(group, artifact, ver), path))
    return files


def build_drivers_xml(custom_entries, driver_defs, maven_versions, remote_ok, resolver):
    """生成完整的 drivers.xml：自定义驱动 + 内置驱动已预取库的 <file> 记录。

    内置驱动只写有已下载文件的库；没有文件的库保持 DBeaver 默认定义不变。
    provider 必须按 <provider id> 分组——解析器没有 endElement 处理，
    <driver> 会挂到最近一个 <provider> 下。
    """
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<drivers>",
    ]
    if custom_entries:
        lines.append('    <provider id="generic">')
        for spec, version, url in custom_entries:
            attrs = {
                "id": spec["id"],
                "name": spec["name"],
                "class": spec["class"],
                "url": spec["url"],
                "port": spec["port"],
                "defaultDatabase": spec["database"],
                "description": "{} (v{})".format(spec["description"], version),
                "custom": "true",
            }
            attr_str = " ".join('{}="{}"'.format(k, _xml_quote(v))
                                for k, v in attrs.items())
            lines.append("        <driver {}>".format(attr_str))
            dest = remote_cache_path(url)
            if os.path.isfile(dest):
                lines.append(
                    '            <library type="jar" path="{}" custom="true">'
                    "<file {}/></library>".format(_xml_quote(url), _file_attr(url, dest)))
            else:
                lines.append('            <library type="jar" path="{}" custom="true"/>'.format(
                    _xml_quote(url)))
            lines.append("        </driver>")
        lines.append("    </provider>")

    # 同一个 (provider, id) 可能被多个插件定义（如 generic 里的占位定义），
    # 按库路径合并，保留第一次出现的顺序
    merged = {}
    for d in driver_defs:
        if not d["provider"]:
            continue
        key = (d["provider"], d["id"])
        entry = merged.setdefault(key, {"libraries": {}})
        for lib in d["libraries"]:
            entry["libraries"].setdefault(lib["path"], lib)

    by_provider = {}
    for (provider, driver_id), entry in merged.items():
        lib_blocks = []   # [(lib, [(id, path)], disabled)]
        for lib in entry["libraries"].values():
            if lib["kind"] == "remote":
                path = remote_cache_path(lib["path"])
                if lib["path"] in remote_ok and os.path.isfile(path):
                    lib_blocks.append((lib, [(lib["path"], path)], False))
                elif lib.get("type") != "jar":
                    # license 之类的非 jar 直链没下下来：显式禁用，避免驱动
                    # 永远因为"缺一个许可证文件"要求下载
                    lib_blocks.append((lib, [], True))
            elif lib["kind"] == "maven":
                files = _maven_library_files(lib, maven_versions, resolver)
                if files:
                    lib_blocks.append((lib, files, False))
        if any(files for _, files, _ in lib_blocks):
            by_provider.setdefault(provider, []).append((driver_id, lib_blocks))

    for provider in sorted(by_provider):
        lines.append('    <provider id="{}">'.format(_xml_quote(provider)))
        for driver_id, lib_blocks in by_provider[provider]:
            lines.append('        <driver id="{}">'.format(_xml_quote(driver_id)))
            for lib, files, disabled in lib_blocks:
                extra = ""
                if lib.get("ignore_deps"):
                    extra += ' ignore-dependencies="true"'
                if lib.get("load_optional"):
                    extra += ' load-optional-dependencies="true"'
                if disabled:
                    extra += ' disabled="true"'
                ftype = lib.get("type") or "jar"
                if not files:
                    lines.append('            <library type="{}" path="{}"{} />'.format(
                        _xml_quote(ftype), _xml_quote(lib["path"]), extra))
                    continue
                lines.append('            <library type="{}" path="{}"{}>'.format(
                    _xml_quote(ftype), _xml_quote(lib["path"]), extra))
                for fid, fpath in files:
                    lines.append("                <file {}/>".format(
                        _file_attr(fid, fpath)))
                lines.append("            </library>")
            lines.append("        </driver>")
        lines.append("    </provider>")

    lines += ["</drivers>", ""]
    return "\n".join(lines)


def prefetch_custom_drivers():
    """解析版本并下载自定义驱动的自包含包。

    返回 [(spec, version, url)]，只包含下载成功的项。
    """
    entries = []
    for spec in CUSTOM_DRIVERS:
        group, artifact, _classifier = spec["maven"]
        version = resolve_latest(group, artifact)
        if not version:
            log("WARN 无法解析最新版本 {}:{}（跳过自定义驱动 {}）".format(
                group, artifact, spec["id"]))
            continue
        url = spec["artifact_url"].format(v=version)
        ok, _ = fetch_remote(url)
        if ok:
            entries.append((spec, version, url))
            log("自定义驱动 {}: {} v{}".format(spec["id"], group + ":" + artifact, version))
    return entries


# ---------------------------------------------------------------- Maven 坐标/路径

def group_path(group):
    return group.replace(".", "/")


def artifact_url(repo, group, artifact, version, ext, classifier=None):
    name = "{}-{}".format(artifact, version)
    if ext == "jar" and classifier:
        name += "-" + classifier
    return "{}{}/{}/{}/{}.{}".format(repo, group_path(group), artifact, version, name, ext)


def cache_path(group, artifact, version, ext, classifier=None):
    name = "{}-{}".format(artifact, version)
    if ext == "jar" and classifier:
        name += "-" + classifier
    # groupId 原样作为目录名（含点的保持点；TiDB 那种带 / 的会自然分层），
    # 与 DBeaver localCacheDir.resolve(groupId + "/" + fileName) 完全一致
    return os.path.join(CACHE, group, "{}.{}".format(name, ext))


def fetch_file(group, artifact, version, ext, classifier=None):
    """下载单个文件到缓存；返回 (ok, 来源描述)。"""
    dest = cache_path(group, artifact, version, ext, classifier)
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        return True, "cached"
    last_err = None
    for repo in REPOS:
        url = artifact_url(repo, group, artifact, version, ext, classifier)
        for attempt in range(2):
            try:
                http_download(url, dest)
                return True, url
            except urllib.error.HTTPError as e:
                last_err = "{} -> HTTP {}".format(url, e.code)
                break  # 404 之类换仓库，不重试
            except Exception as e:  # 网络抖动
                last_err = "{} -> {}".format(url, e)
                if attempt == 0:
                    time.sleep(2)
    log("WARN 下载失败: {}:{}:{} [{}] {}".format(group, artifact, version, ext, last_err))
    return False, last_err


# ---------------------------------------------------------------- POM 解析

def _text(el, tag):
    if el is None:
        return None
    child = el.find(tag)
    if child is None or child.text is None:
        return None
    v = child.text.strip()
    return v or None


def _strip_ns(root):
    """Maven POM 默认带 xmlns，ElementTree 会把命名空间拼进 tag，去掉它再按本地名查。"""
    for el in root.iter():
        if isinstance(el.tag, str) and "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    return root


def _bool(v):
    return (v or "").strip().lower() == "true"


PROP_RE = re.compile(r"\$\{([^}]+)\}")


def substitute(value, props, depth=10):
    if not value:
        return value
    for _ in range(depth):
        new = PROP_RE.sub(lambda m: props.get(m.group(1), m.group(0)), value)
        if new == value:
            break
        value = new
    return value


class Pom(object):
    def __init__(self, group, artifact, version):
        self.group = group
        self.artifact = artifact
        self.version = version
        self.packaging = None
        self.props = {}
        self.deps = []          # 未过滤的原始 dependency dict
        self.dep_mgmt = []      # dependencyManagement dict
        self.parent = None      # Pom
        self.loaded = False


class Resolver(object):
    def __init__(self):
        self.poms = {}            # (g,a,v) -> Pom 或 None
        self.pom_lock = threading.Lock()
        self.downloaded = []      # (g,a,v,ext)
        self.failed = []
        self.missing_refs = []
        # 根坐标 -> [(g,a,v,ext,classifier)]，主 jar + 传递依赖的扁平列表，
        # 即 DBeaver 下载完成后 resolvedFiles 里一个根库对应的全部文件
        self.files_by_root = {}

    # ---- POM 获取
    def get_pom(self, group, artifact, version, classifier=None):
        key = (group, artifact, version)
        with self.pom_lock:
            pom = self.poms.get(key)
        if pom is not None or key in self.poms:
            return pom
        ok, _ = fetch_file(group, artifact, version, "pom")
        if not ok:
            with self.pom_lock:
                self.poms[key] = None
            return None
        path = cache_path(group, artifact, version, "pom")
        try:
            with open(path, "rb") as f:
                data = f.read()
            root = _strip_ns(ET.fromstring(data))
        except Exception as e:
            log("WARN 解析 POM 失败 {}:{}:{}: {}".format(group, artifact, version, e))
            with self.pom_lock:
                self.poms[key] = None
            return None
        pom = Pom(group, artifact, version)
        pom.packaging = _text(root, "packaging")
        self._parse_properties(root, pom.props)
        # parent
        parent_el = root.find("parent")
        if parent_el is not None:
            pg, pa, pv = _text(parent_el, "groupId"), _text(parent_el, "artifactId"), _text(parent_el, "version")
            if pg and pa and pv:
                pom.parent = self.get_pom(pg, pa, pv)
                if pom.parent is None:
                    log("WARN 父 POM 解析失败 {}:{}:{}".format(pg, pa, pv))
        # 默认 profile（就是根节点）以及激活的 profile
        self._parse_profile(root, pom, is_default=True)
        for prof in root.findall("profiles/profile"):
            if not self._profile_active(prof):
                continue
            sub = Pom(group, artifact, version)
            sub.parent = pom.parent
            sub.props = dict(pom.props)
            self._parse_profile(prof, sub, is_default=False)
            # 合并激活 profile 的属性/依赖
            pom.props.update(sub.props)
            pom.deps.extend(sub.deps)
            pom.dep_mgmt.extend(sub.dep_mgmt)
        pom.loaded = True
        with self.pom_lock:
            self.poms[key] = pom
        return pom

    @staticmethod
    def _parse_properties(root, into):
        props = root.find("properties")
        if props is None:
            return
        for p in list(props):
            into[p.tag] = (p.text or "").strip()

    @staticmethod
    def _profile_active(prof):
        act = prof.find("activation")
        if act is None:
            return False
        if _bool(_text(act, "activeByDefault")):
            return True
        prop = act.find("property")
        if prop is not None:
            name = _text(prop, "name") or ""
            # 与 DBeaver 一致：只实现 "!prop" 这种否定激活
            if name.startswith("!"):
                return True
        return False

    def _parse_profile(self, element, pom, is_default):
        deps_el = element.find("dependencies")
        if deps_el is not None:
            for d in deps_el.findall("dependency"):
                pom.deps.append(self._dep_dict(d))
        dm_el = element.find("dependencyManagement")
        if dm_el is not None:
            inner = dm_el.find("dependencies")
            if inner is not None:
                for d in inner.findall("dependency"):
                    pom.dep_mgmt.append(self._dep_dict(d))

    @staticmethod
    def _dep_dict(d):
        return {
            "group": _text(d, "groupId"),
            "artifact": _text(d, "artifactId"),
            "version": _text(d, "version"),
            "type": _text(d, "type") or "jar",
            "classifier": _text(d, "classifier"),
            "scope": _text(d, "scope"),
            "optional": _bool(_text(d, "optional")),
        }

    # ---- 属性/依赖管理
    @staticmethod
    def _props_for(pom):
        chain = []
        m = pom
        while m is not None:
            chain.append(m)
            m = m.parent
        props = {}
        for m in reversed(chain):  # 根到叶，子覆盖父
            props.update(m.props)
        leaf = pom
        props.setdefault("project.groupId", leaf.group)
        props.setdefault("project.artifactId", leaf.artifact)
        props.setdefault("project.version", leaf.version)
        props.setdefault("version", leaf.version)
        props.setdefault("groupId", leaf.group)
        props.setdefault("artifactId", leaf.artifact)
        if leaf.parent is not None:
            props.setdefault("project.parent.groupId", leaf.parent.group)
            props.setdefault("project.parent.artifactId", leaf.parent.artifact)
            props.setdefault("project.parent.version", leaf.parent.version)
            props.setdefault("parent.version", leaf.parent.version)
        # 属性之间可能互相引用，展开两次足够覆盖常见 POM
        for _ in range(2):
            for k, v in list(props.items()):
                if isinstance(v, str) and "${" in v:
                    props[k] = substitute(v, props)
        return props

    def _find_dm(self, pom, group, artifact, dep_type, classifier, seen=None):
        """返回按 DM 所在 POM 属性展开后的 dependencyManagement 条目。"""
        seen = seen or set()
        if pom is None or (id(pom), group, artifact) in seen:
            return None
        seen.add((id(pom), group, artifact))
        props = self._props_for(pom)
        for dm in pom.dep_mgmt:
            if (dm["group"] == group and dm["artifact"] == artifact
                    and dm["type"] == dep_type and dm["classifier"] == classifier):
                return {k: (substitute(v, props) if isinstance(v, str) else v)
                        for k, v in dm.items()}
        # BOM import：DBeaver 会递归进 import 的 POM 查 dependencyManagement
        for dm in pom.dep_mgmt:
            if (dm["scope"] or "").lower() == "import":
                ver = substitute(dm["version"], props) if dm["version"] else None
                if not ver or "${" in ver:
                    continue
                inner = self.get_pom(dm["group"], dm["artifact"], ver, dm["classifier"])
                found = self._find_dm(inner, group, artifact, dep_type, classifier, seen)
                if found:
                    return found
        return self._find_dm(pom.parent, group, artifact, dep_type, classifier, seen)

    # ---- 主流程
    def add_artifact(self, group, artifact, version, classifier=None, optional_mode=False):
        """下载主 jar + pom，并递归下载依赖。返回该根库的文件列表。"""
        label = "{}:{}:{}".format(group, artifact, version)
        collected = []
        if classifier in SKIP_CLASSIFIERS:
            self.files_by_root[(group, artifact, version, classifier)] = collected
            return collected
        ok, _ = fetch_file(group, artifact, version, "jar", classifier)
        self.downloaded.append((group, artifact, version, "jar"))
        if not ok:
            self.failed.append(label)
        else:
            collected.append((group, artifact, version, "jar", classifier))
        pom = self.get_pom(group, artifact, version)
        if pom is not None:
            self._walk_deps(pom, optional_mode, set(), label, collected)
        self.files_by_root[(group, artifact, version, classifier)] = collected
        return collected

    def _walk_deps(self, pom, optional_mode, visited, root_label, collected):
        key = (pom.group, pom.artifact, pom.version)
        if key in visited:
            return
        visited.add(key)
        props = self._props_for(pom)
        for raw in pom.deps:
            dep = {k: substitute(v, props) if isinstance(v, str) else v
                   for k, v in raw.items()}
            group, artifact = dep["group"], dep["artifact"]
            if not group or not artifact:
                continue
            dep_type = dep["type"] or "jar"
            classifier = dep["classifier"]
            dm = self._find_dm(pom, group, artifact, dep_type, classifier)
            scope = (dep["scope"] or (dm["scope"] if dm else None) or "compile").lower()
            optional = dep["optional"] or (not dep["optional"] and dm is not None and dm["optional"])
            version = dep["version"] or (dm["version"] if dm else None)

            if scope == "import":
                # BOM，只用于 dependencyManagement，已由 _find_dm 处理
                continue
            if optional_mode:
                if scope not in ("compile", "runtime", "provided"):
                    continue
            else:
                if optional or scope not in ("compile", "runtime"):
                    continue
            if not version or "${" in version:
                log("WARN 无法解析依赖版本 {}:{}（来自 {}）".format(group, artifact, root_label))
                continue
            if dep_type == "pom":
                # pom 依赖只用于继承，不下载 jar
                self.get_pom(group, artifact, version, classifier)
                continue
            if classifier in SKIP_CLASSIFIERS:
                continue
            ok, _ = fetch_file(group, artifact, version, "jar", classifier)
            self.downloaded.append((group, artifact, version, "jar"))
            if not ok:
                self.failed.append("{}:{}:{}".format(group, artifact, version))
            else:
                collected.append((group, artifact, version, "jar", classifier))
            sub = self.get_pom(group, artifact, version, classifier)
            if sub is not None:
                self._walk_deps(sub, optional_mode, visited, root_label, collected)


# ---------------------------------------------------------------- 驱动定义

def parse_maven_ref(path):
    """解析 plugin.xml 里的 maven:/... 引用，语义与 MavenArtifactReference 一致。

    返回 (group, artifact, classifier, preferred_version)；
    preferred_version 为 None 表示定义写的是 RELEASE，需要查元数据取最新。
    """
    p = path.strip()
    preferred = None
    if p.endswith("]"):
        i = p.rfind("[")
        if i != -1:
            preferred = p[i + 1:-1].strip()
            p = p[:i]
    # [LATEST] / [RELEASE] 在 DBeaver 里同样是"查元数据取最新"，不是版本号
    if preferred and preferred.upper() in ("LATEST", "RELEASE"):
        preferred = None
    if not p.startswith("maven:"):
        return None
    p = p[len("maven:"):]
    if p.startswith("/"):
        p = p[1:]
    parts = p.split(":")
    if len(parts) == 1:
        group = artifact = parts[0]
        classifier = None
    elif len(parts) == 2:
        group, artifact = parts
        classifier = None
    elif len(parts) == 3:
        # 第三段在 DBeaver 里是 fallbackVersion，真正版本仍是 RELEASE
        group, artifact, _ = parts
        classifier = None
    else:
        group, artifact, classifier = parts[0], parts[1], parts[2]
    return group, artifact, classifier, preferred


def resolve_latest(group, artifact):
    """RELEASE 引用：从 Maven 元数据里取最新 release 版本。"""
    gp = group_path(group)
    for repo in REPOS:
        url = "{}{}/{}/maven-metadata.xml".format(repo, gp, artifact)
        try:
            root = ET.fromstring(http_get(url, timeout=60))
        except Exception:
            continue
        ver = root.find("versioning")
        if ver is None:
            continue
        release = _text(ver, "release")
        latest = _text(ver, "latest")
        versions = [(v.text or "").strip() for v in ver.findall("versions/version")]
        versions = [v for v in versions if v and "SNAPSHOT" not in v.upper()]
        candidate = release or latest
        if not candidate or "SNAPSHOT" in candidate.upper():
            candidate = None
        if candidate is None and versions:
            candidate = versions[-1]
        if candidate:
            return candidate
    return None


def collect_driver_defs(plugins_dir):
    """从已安装 DBeaver 的 plugin.xml 里收集白名单驱动的库定义。

    返回 (driver_defs, refs, remote_urls, skipped)：
      driver_defs:  [{"id", "provider", "libraries": [...]}]，用于生成 drivers.xml
      refs:         (group, artifact, classifier) -> {preferred, optional}
      remote_urls:  url -> FileType（GaussDB 的 gsjdbc4 jar、H2/Oracle 等的 license 直链）
      skipped:      其它非 maven、非直链的路径（bundle / drivers/... 安装包）
    """
    refs = {}
    remote_urls = {}
    skipped = []
    driver_defs = []
    for name in sorted(os.listdir(plugins_dir)):
        if not (name.startswith("org.jkiss.dbeaver.ext.") and name.endswith(".jar")):
            continue
        if ".ui." in name:
            continue
        jar = os.path.join(plugins_dir, name)
        try:
            data = zipfile.ZipFile(jar).read("plugin.xml")
        except (KeyError, zipfile.BadZipFile, OSError):
            continue
        try:
            root = ET.fromstring(data)
        except ET.ParseError:
            continue
        for ds in root.iter("datasource"):
            provider_id = (ds.get("id") or "").strip()
            for el in ds.iter("driver"):
                driver_id = el.get("id")
                if driver_id not in DRIVER_IDS:
                    continue
                # 同 id 可能出现在别的插件的 replace/占位定义里（如 generic 里的
                # <driver id="sqlite_jdbc" dataSourceType="sqlite"/>，没有库定义），
                # 这里全部收集，生成 XML 时再按 (provider, id) 合并。
                libraries = []
                for f in el.findall("file"):
                    ftype = (f.get("type") or "jar").strip()
                    path = (f.get("path") or "").strip()
                    if not path:
                        continue
                    opt = (f.get("load-optional-dependencies") or "").strip().lower() == "true"
                    if path.startswith("http://") or path.startswith("https://"):
                        # jar 之外还有 license 直链（H2/Oracle 等）。DBeaver 判断
                        # 驱动是否齐全时连 license 库一起检查，所以这些也要预取，
                        # 否则首次连接仍会弹下载框（而且待下载列表是空的）。
                        # 同一 URL 被多个驱动引用时，按最"硬"的类型记（jar 优先）
                        if remote_urls.get(path) != "jar":
                            remote_urls[path] = ftype
                        libraries.append({"path": path, "kind": "remote",
                                          "type": ftype, "optional": opt})
                        continue
                    if not (ftype == "jar" and path.startswith("maven:/")):
                        skipped.append((driver_id, path))
                        libraries.append({"path": path, "kind": "other", "type": ftype})
                        continue
                    parsed = parse_maven_ref(path)
                    if not parsed:
                        continue
                    group, artifact, classifier, preferred = parsed
                    key = (group, artifact, classifier)
                    old = refs.get(key)
                    if old is None:
                        refs[key] = {"preferred": preferred, "optional": opt}
                    else:
                        # 固定版本优先于 RELEASE；optional 取并集
                        if old["preferred"] is None and preferred is not None:
                            old["preferred"] = preferred
                        old["optional"] = old["optional"] or opt
                    libraries.append({
                        "path": path,
                        "kind": "maven",
                        "type": ftype,
                        "group": group,
                        "artifact": artifact,
                        "classifier": classifier,
                        "optional": opt,
                        # plugin.xml 里的这两个属性要原样写回 drivers.xml，
                        # 否则解析器会用 false 覆盖掉驱动定义里的设置
                        "ignore_deps": (f.get("ignore-dependencies") or "").strip().lower() == "true",
                        "load_optional": opt,
                    })
                driver_defs.append({
                    "id": driver_id,
                    "provider": provider_id,
                    "libraries": libraries,
                })
    return driver_defs, refs, remote_urls, skipped


# ---------------------------------------------------------------- main

def main():
    if not os.path.isdir(PLUGINS):
        log("ERROR 找不到 DBeaver 插件目录: " + PLUGINS)
        return 1
    driver_defs, refs, remote_urls, skipped = collect_driver_defs(PLUGINS)
    if not refs and not remote_urls:
        log("ERROR 没有从驱动定义里解析到任何库（DBEAVER_DRIVER_IDS={}）".format(",".join(sorted(DRIVER_IDS))))
        return 1

    log("预取 {} 个 maven 驱动库到 {}，{} 个直链库到 {}（另自定义驱动 {} 个）".format(
        len(refs), CACHE, len(remote_urls), REMOTE_ROOT, len(CUSTOM_DRIVERS)))
    resolver = Resolver()
    tasks = []
    maven_versions = {}
    for (group, artifact, classifier), info in sorted(
            refs.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2] or "")):
        version = info["preferred"]
        if not version:
            version = resolve_latest(group, artifact)
            if not version:
                log("WARN 无法解析最新版本 {}:{}".format(group, artifact))
                resolver.missing_refs.append("{}:{}".format(group, artifact))
                continue
        tasks.append((group, artifact, version, classifier, info["optional"]))
        maven_versions[(group, artifact, classifier)] = version

    # 同一坐标可能被多个驱动复用（MySQL/Doris/TiDB），去重
    tasks = sorted(set(tasks), key=lambda t: (t[0], t[1], t[3] or "", t[2]))

    def run(task):
        group, artifact, version, classifier, optional_mode = task
        try:
            resolver.add_artifact(group, artifact, version, classifier, optional_mode)
        except Exception as e:
            log("WARN 处理 {}:{}:{} 失败: {}".format(group, artifact, version, e))
            resolver.failed.append("{}:{}:{}".format(group, artifact, version))

    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        list(pool.map(run, tasks))

        def run_remote(item):
            url, ftype = item
            if ftype == "jar":
                return fetch_remote(url)
            # license 等附属文件只是给驱动管理器显示用，下载不到就禁用该库
            # （见 build_drivers_xml）。用短超时+单次尝试：github raw 直链在
            # 部分网络（无代理的内网/受限网络）不可达，不值得等默认的 180s×2。
            return fetch_remote(url, timeout=15, attempts=1)

        remote_urls_sorted = sorted(remote_urls.items())
        remote_results = list(pool.map(run_remote, remote_urls_sorted))
    remote_ok = {u for (u, _t), (ok, _) in zip(remote_urls_sorted, remote_results) if ok}
    remote_jar_ok = {u for (u, t), (ok, _) in zip(remote_urls_sorted, remote_results)
                     if ok and t == "jar"}

    # DBeaver CE 没有的数据库（Redis）用自定义驱动补上
    custom_entries = prefetch_custom_drivers()

    # 生成 drivers.xml：自定义驱动 + 内置驱动已预取库的 <file> 记录。
    # 没有 <file> 记录时，DBeaver 即使看到缓存里的 jar 也会要求重新下载。
    out = os.environ.get("DBEAVER_CUSTOM_DRIVERS_OUT")
    if out:
        xml = build_drivers_xml(custom_entries, driver_defs, maven_versions, remote_ok, resolver)
        with open(out, "w", encoding="utf-8") as f:
            f.write(xml)
        recorded = xml.count("<file ")
        log("已生成驱动配置: {}（{} 条已预取文件记录）".format(out, recorded))

    # 统计
    jars = [p for p in _walk_files(CACHE) if p.endswith(".jar")]
    poms = [p for p in _walk_files(CACHE) if p.endswith(".pom")]
    total = sum(os.path.getsize(p) for p in jars + poms)
    remote_files = []
    if os.path.isdir(REMOTE_ROOT):
        remote_files = [p for p in _walk_files(REMOTE_ROOT) if p.endswith(".jar")]
    remote_size = sum(os.path.getsize(p) for p in remote_files)
    log("完成: {} 个 maven jar, {} 个 pom, {:.1f} MB；{} 个直链 jar, {:.1f} MB".format(
        len(jars), len(poms), total / 1048576.0, len(remote_files), remote_size / 1048576.0))
    if resolver.missing_refs:
        log("WARN 无法确定版本的库: " + ", ".join(resolver.missing_refs))
    if resolver.failed:
        log("WARN 下载失败的库: " + ", ".join(sorted(set(resolver.failed))))
    # bundle / 安装包形式的库（drivers/...）留给安装包或运行期联网下载
    for driver_id, path in skipped:
        log("跳过非 maven/直链库 [{}]: {}".format(driver_id, path))
    if not jars and not remote_jar_ok:
        log("ERROR 一个驱动库都没下下来")
        return 1
    return 0


def _walk_files(root):
    for dirpath, _, files in os.walk(root):
        for f in files:
            yield os.path.join(dirpath, f)


if __name__ == "__main__":
    sys.exit(main())
