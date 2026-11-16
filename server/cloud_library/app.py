#!/usr/bin/env python3
"""仅使用 Python 标准库的私人稿件库；不提供远程提词或录音功能。"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hmac
import html
import json
import os
from pathlib import Path
import re
import sqlite3
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import uuid

FORMAT = "storm-cloud-library"
VERSION = 1
MAX_REQUEST_BYTES = 1024 * 1024
MAX_BODY_UNITS = 50_000
MAX_CONTENT_UNITS = 400_000
MAX_TOTAL_BODY_UNITS = 8_000_000
MAX_TOTAL_CONTENT_UNITS = 24_000_000
MAX_SCRIPTS = 1000
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
BACKUP_FORMAT = "storm-cloud-backup"
MAX_FOLDERS = 1000
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\Z", re.ASCII)
SCRIPT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z", re.ASCII)


class LibraryError(Exception):
    def __init__(self, message: str, code: str = "invalid_request", status: int = 400):
        super().__init__(message)
        self.message, self.code, self.status = message, code, status


def utf16_units(value: str) -> int:
    return len(value.encode("utf-16-le")) // 2


def encode_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def render_content(body: str) -> str:
    """与客户端一致：每行独立段落；只转义文字，不执行 Markdown/HTML。"""
    return "\n".join("<p>" + html.escape(line, quote=False) + "</p>" for line in body.split("\n"))


def parse_markdown(raw: bytes | str) -> tuple[str, str, str]:
    if isinstance(raw, str):
        try:
            raw = raw.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise LibraryError("文档含有无效 Unicode 字符", "invalid_utf8") from exc
    if len(raw) > MAX_REQUEST_BYTES:
        raise LibraryError("文档超过 1 MiB 上传限制", "request_too_large", 413)
    try:
        document = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise LibraryError("文档必须使用 UTF-8 编码", "invalid_utf8") from exc
    document = document.replace("\r\n", "\n").replace("\r", "\n")
    if "\x00" in document:
        raise LibraryError("文档不能包含空字符", "invalid_markdown")
    lines = document.split("\n")
    if not lines or lines[0].strip() != "---":
        raise LibraryError("文档必须以 --- 包围的 script_id 字段开头", "missing_frontmatter")
    try:
        closing = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration as exc:
        raise LibraryError("script_id 信息区缺少结束的 ---", "invalid_frontmatter") from exc
    fields = [line for line in lines[1:closing] if line.strip()]
    if len(fields) != 1:
        raise LibraryError("信息区只能包含一个 script_id 字段，不能重复或增加其他字段", "invalid_frontmatter")
    field = re.fullmatch(r"script_id:[ \t]*(.+?)[ \t]*", fields[0])
    if field is None:
        raise LibraryError("信息区必须且只能使用 script_id 字段", "invalid_frontmatter")
    script_id = field.group(1)
    if script_id.startswith(('"', "'")):
        quote = script_id[0]
        if len(script_id) < 2 or script_id[-1] != quote:
            raise LibraryError("script_id 的引号必须成对出现", "invalid_script_id")
        script_id = script_id[1:-1]
    if SCRIPT_ID.fullmatch(script_id) is None:
        raise LibraryError("脚本编号需为 1–64 位英文字母、数字、点、下划线或短横线，且以字母或数字开头", "invalid_script_id")
    start = None
    end = len(lines)
    for i in range(closing + 1, len(lines)):
        heading = re.fullmatch(r"(#{1,6})[ \t]+(.*?)[ \t]*", lines[i])
        if heading is None:
            continue
        title = re.sub(r"[ \t]+#+[ \t]*$", "", heading.group(2)).strip()
        if start is None:
            if len(heading.group(1)) == 2 and title == "正文":
                start = i + 1
        elif len(heading.group(1)) <= 2:
            end = i
            break
    if start is None:
        raise LibraryError("文档缺少二级标题“## 正文”", "missing_body")
    body = "\n".join(lines[start:end]).strip()
    if not body:
        raise LibraryError("正文不能为空", "empty_body")
    if utf16_units(body) > MAX_BODY_UNITS:
        raise LibraryError("单篇正文不能超过 50000 个 UTF-16 单位", "body_too_large", 413)
    content = render_content(body)
    if utf16_units(content) > MAX_CONTENT_UNITS:
        raise LibraryError("排版后的单篇正文超过长度限制", "content_too_large", 413)
    return script_id, body, content


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_json(raw: bytes) -> object:
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_keys,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")))
    except (ValueError, UnicodeError, RecursionError):
        raise LibraryError("JSON 格式无效或包含重复字段", "invalid_json") from None


def validate_backup(value: object) -> dict:
    """Whitelist the content-only format before any persistent change."""
    def invalid(message="稿件和文件夹备份格式无效"):
        raise LibraryError(message, "invalid_backup")

    def text(item, maximum, *, empty=False):
        if not isinstance(item, str) or (not empty and not item.strip()) or "\x00" in item:
            invalid()
        try:
            if utf16_units(item) > maximum:
                invalid("备份中的文字长度超过限制")
        except UnicodeError:
            invalid("备份含无效 Unicode 字符")
        return item

    def timestamp(item):
        if not isinstance(item, str) or not TIMESTAMP.fullmatch(item):
            invalid("备份时间必须是有效 UTC 时间")
        try:
            return datetime.fromisoformat(item[:-1] + "+00:00")
        except ValueError:
            invalid("备份时间超出有效日历范围")

    def order(item):
        if type(item) is not int or abs(item) > 9007199254740991:
            invalid("排序值无效")

    if not isinstance(value, dict) or set(value) != {"format", "version", "createdAt", "articles", "folders"}:
        invalid("备份只能包含稿件和文件夹，不得包含设备设置或其他字段")
    if value["format"] != BACKUP_FORMAT or type(value["version"]) is not int or value["version"] != 1:
        invalid("不支持此云端总备份格式或版本")
    timestamp(value["createdAt"])
    articles, folders = value["articles"], value["folders"]
    if not isinstance(articles, list) or not isinstance(folders, list):
        invalid()
    if len(articles) > MAX_SCRIPTS or len(folders) > MAX_FOLDERS:
        raise LibraryError("总备份最多包含 1000 篇稿件和 1000 个文件夹", "backup_too_large", 413)
    folder_ids = set()
    parents = {}
    for folder in folders:
        required = {"id", "name", "createdAt", "sortOrder"}
        if not isinstance(folder, dict) or not required <= set(folder) or set(folder) - required - {"parentId"}:
            invalid()
        identity = text(folder["id"], 256)
        if identity in folder_ids:
            invalid("文件夹 ID 重复")
        folder_ids.add(identity)
        text(folder["name"], 512)
        timestamp(folder["createdAt"])
        order(folder["sortOrder"])
        parent = folder.get("parentId")
        if parent is not None:
            text(parent, 256)
        parents[identity] = parent
    complete = set()
    for identity in folder_ids:
        cursor, path = identity, set()
        while cursor is not None and cursor not in complete:
            if cursor not in folder_ids:
                invalid("文件夹引用了不存在的上级目录")
            if cursor in path:
                invalid("文件夹不能循环引用")
            path.add(cursor)
            cursor = parents[cursor]
        complete.update(path)
    article_ids = set()
    total = 0
    for article in articles:
        required = {"id", "title", "content", "createdAt", "updatedAt", "sortOrder"}
        if not isinstance(article, dict) or not required <= set(article) or set(article) - required - {"folderId"}:
            invalid("稿件备份不得包含设备提词设置或其他字段")
        identity = text(article["id"], 256)
        if identity in article_ids:
            invalid("稿件 ID 重复")
        article_ids.add(identity)
        text(article["title"], 512, empty=True)
        text(article["content"], MAX_CONTENT_UNITS, empty=True)
        total += utf16_units(article["content"])
        if total > MAX_TOTAL_CONTENT_UNITS:
            raise LibraryError("备份正文总长度超过限制", "backup_too_large", 413)
        if timestamp(article["updatedAt"]) < timestamp(article["createdAt"]):
            invalid("稿件更新时间不能早于创建时间")
        order(article["sortOrder"])
        folder_id = article.get("folderId")
        if folder_id is not None:
            text(folder_id, 256)
            if folder_id not in folder_ids:
                invalid("稿件引用了不存在的文件夹")
    if len(encode_json(value)) > MAX_RESPONSE_BYTES - 1024:
        raise LibraryError("总备份超过 32 MiB 限制", "backup_too_large", 413)
    return value


class Library:
    def __init__(self, directory: Path | str):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory.chmod(0o700)
        self.path = self.directory / "library.sqlite3"
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS scripts (
                    script_id TEXT PRIMARY KEY, body TEXT NOT NULL, content TEXT NOT NULL,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, revision INTEGER NOT NULL
                );
            """)
            db.execute("INSERT OR IGNORE INTO metadata VALUES ('library_id', ?)", (str(uuid.uuid4()),))
            db.execute("INSERT OR IGNORE INTO metadata VALUES ('revision', '0')")
        self.path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=30000")
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def script(row: sqlite3.Row) -> dict:
        return {"scriptId": row["script_id"], "title": row["script_id"], "body": row["body"],
                "content": row["content"], "createdAt": row["created_at"],
                "updatedAt": row["updated_at"], "revision": row["revision"]}

    def _snapshot(self, db: sqlite3.Connection) -> dict:
        metadata = dict(db.execute("SELECT key, value FROM metadata"))
        return {"format": FORMAT, "version": VERSION, "libraryId": metadata["library_id"],
                "revision": int(metadata["revision"]),
                "scripts": [self.script(row) for row in db.execute("SELECT * FROM scripts ORDER BY script_id COLLATE BINARY")]}

    @staticmethod
    def validate_snapshot(snapshot: dict) -> bytes:
        scripts = snapshot["scripts"]
        if len(scripts) > MAX_SCRIPTS:
            raise LibraryError("稿库最多保存 1000 篇脚本", "library_full", 413)
        if sum(utf16_units(s["body"]) for s in scripts) > MAX_TOTAL_BODY_UNITS:
            raise LibraryError("稿库正文总长度超过限制", "library_too_large", 413)
        if sum(utf16_units(s["content"]) for s in scripts) > MAX_TOTAL_CONTENT_UNITS:
            raise LibraryError("稿库排版总长度超过限制", "library_too_large", 413)
        payload = encode_json(snapshot)
        if len(payload) > MAX_RESPONSE_BYTES:
            raise LibraryError("稿库响应超过 32 MiB 限制", "library_too_large", 413)
        return payload

    def snapshot_bytes(self) -> bytes:
        with self.connect() as db:
            db.execute("BEGIN")
            if db.execute("SELECT 1 FROM metadata WHERE key='content_backup'").fetchone():
                raise LibraryError("稿库已启用整库备份，请升级到支持上传与整库恢复的新版客户端", "upgrade_required", 426)
            return self.validate_snapshot(self._snapshot(db))

    def _backup(self, db: sqlite3.Connection) -> dict:
        stored = db.execute("SELECT value FROM metadata WHERE key='content_backup'").fetchone()
        if stored:
            return validate_backup(parse_json(stored[0].encode("utf-8")))
        snapshot = self._snapshot(db)
        if not snapshot["scripts"]:
            raise LibraryError("云端尚无总备份，请先从有稿件的设备上传", "no_backup", 404)
        articles = [{"id": f'cloud:{snapshot["libraryId"]}:{script["scriptId"]}',
                     "title": script["title"], "content": render_content(script["body"]),
                     "createdAt": script["createdAt"], "updatedAt": script["updatedAt"],
                     "sortOrder": index} for index, script in enumerate(snapshot["scripts"])]
        return validate_backup({"format": BACKUP_FORMAT, "version": 1,
                                "createdAt": max(s["updatedAt"] for s in snapshot["scripts"]),
                                "articles": articles, "folders": []})

    def backup_bytes(self) -> bytes:
        with self.connect() as db:
            db.execute("BEGIN")
            revision = int(db.execute("SELECT value FROM metadata WHERE key='revision'").fetchone()[0])
            return encode_json({"revision": revision, "backup": self._backup(db)})

    def replace_backup(self, raw: bytes) -> dict:
        backup = validate_backup(parse_json(raw))
        encoded = encode_json(backup).decode("utf-8")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            revision = int(db.execute("SELECT value FROM metadata WHERE key='revision'").fetchone()[0]) + 1
            db.execute("INSERT OR REPLACE INTO metadata VALUES ('content_backup', ?)", (encoded,))
            db.execute("UPDATE metadata SET value=? WHERE key='revision'", (str(revision),))
            # No retained generations: the current snapshot is authoritative.
            db.execute("DELETE FROM scripts")
        return {"success": True, "articles": len(backup["articles"]),
                "folders": len(backup["folders"]), "revision": revision}

    def import_markdown(self, raw: bytes) -> dict:
        script_id, body, content = parse_markdown(raw)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM metadata WHERE key='content_backup'").fetchone():
                backup = self._backup(db)
                library_id = db.execute("SELECT value FROM metadata WHERE key='library_id'").fetchone()[0]
                identity = f"cloud:{library_id}:{script_id}"
                old = next((a for a in backup["articles"] if a["id"] == identity), None)
                revision = int(db.execute("SELECT value FROM metadata WHERE key='revision'").fetchone()[0])
                if old is None or old["content"] != content or old["title"] != script_id:
                    revision += 1
                    now = utc_now()
                    article = {"id": identity, "title": script_id, "content": content,
                               "createdAt": old["createdAt"] if old else now,
                               "updatedAt": now, "sortOrder": old["sortOrder"] if old else len(backup["articles"])}
                    if old and old.get("folderId") is not None:
                        article["folderId"] = old["folderId"]
                    backup["articles"] = [article if a["id"] == identity else a for a in backup["articles"]]
                    if old is None:
                        backup["articles"].append(article)
                    backup["createdAt"] = now
                    validate_backup(backup)
                    db.execute("UPDATE metadata SET value=? WHERE key='content_backup'", (encode_json(backup).decode("utf-8"),))
                    db.execute("UPDATE metadata SET value=? WHERE key='revision'", (str(revision),))
                return {"created": old is None, "script": {"scriptId": script_id, "title": script_id,
                        "body": body, "content": content, "revision": revision}}
            old = db.execute("SELECT * FROM scripts WHERE script_id = ?", (script_id,)).fetchone()
            if old is not None and old["body"] == body:
                return {"created": False, "script": self.script(old)}
            revision = int(db.execute("SELECT value FROM metadata WHERE key='revision'").fetchone()[0]) + 1
            now = utc_now()
            if old is None:
                db.execute("INSERT INTO scripts VALUES (?, ?, ?, ?, ?, ?)", (script_id, body, content, now, now, revision))
            else:
                db.execute("UPDATE scripts SET body=?, content=?, updated_at=?, revision=? WHERE script_id=?",
                           (body, content, now, revision, script_id))
            db.execute("UPDATE metadata SET value=? WHERE key='revision'", (str(revision),))
            self.validate_snapshot(self._snapshot(db))  # Failure rolls the entire transaction back.
            row = db.execute("SELECT * FROM scripts WHERE script_id=?", (script_id,)).fetchone()
            return {"created": old is None, "script": self.script(row)}


def validate_token(token: str) -> str:
    if not 32 <= len(token) <= 512 or any(c.isspace() for c in token) or not token.isascii():
        raise ValueError("读令牌和上传令牌必须分别为 32–512 位 ASCII 随机字符串，不含空白")
    return token


class LibraryHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], library: Library, read_token: str, upload_token: str):
        self.library = library
        self.read_token = validate_token(read_token)
        self.upload_token = validate_token(upload_token)
        if hmac.compare_digest(self.read_token, self.upload_token):
            raise ValueError("读令牌和上传令牌必须不同")
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server: LibraryHTTPServer
    server_version = "StormCloudLibrary"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(20)

    def log_message(self, format: str, *args):
        # Deliberately omit paths, headers, query strings, credentials and script contents.
        return

    def _send(self, status: int, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, error: LibraryError):
        self._send(error.status, encode_json({"error": {"code": error.code, "message": error.message}}))

    def _route(self) -> str:
        target = urlsplit(self.path)
        if target.query or target.fragment:
            raise LibraryError("接口地址不能包含查询参数或凭据", "query_not_allowed")
        return target.path

    def _authorize(self, write: bool = False):
        headers = self.headers.get_all("Authorization", [])
        value = headers[0] if len(headers) == 1 else ""
        token = value[7:] if value.startswith("Bearer ") else ""
        try:
            candidate = token.encode("ascii")
        except UnicodeEncodeError:
            candidate = b""
        # Always compare both secrets, including invalid/missing headers.
        readable = hmac.compare_digest(candidate, self.server.read_token.encode("ascii"))
        writable = hmac.compare_digest(candidate, self.server.upload_token.encode("ascii"))
        if not readable and not writable:
            raise LibraryError("需要有效的访问令牌", "unauthorized", 401)
        if write and not writable:
            raise LibraryError("读令牌不能上传脚本", "forbidden", 403)

    def do_GET(self):
        try:
            route = self._route()
            if route == "/healthz":
                self._send(200, encode_json({"status": "ok"}))
            elif route == "/api/v1/library":
                self._authorize()
                self._send(200, self.server.library.snapshot_bytes())
            elif route == "/api/v1/backup":
                self._authorize()
                self._send(200, self.server.library.backup_bytes())
            else:
                raise LibraryError("接口不存在", "not_found", 404)
        except LibraryError as exc:
            self._error(exc)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            self._error(LibraryError("稿库暂时不可用", "internal_error", 500))

    def do_PUT(self):
        try:
            if self._route() != "/api/v1/backup":
                raise LibraryError("接口不存在", "not_found", 404)
            self._authorize(write=True)
            content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise LibraryError("总备份必须使用 UTF-8 application/json", "unsupported_media_type", 415)
            lengths = self.headers.get_all("Content-Length", [])
            if self.headers.get("Transfer-Encoding") or len(lengths) != 1:
                raise LibraryError("上传必须携带唯一 Content-Length，不支持分块编码", "invalid_content_length", 411)
            try:
                size = int(lengths[0])
            except ValueError as exc:
                raise LibraryError("Content-Length 无效", "invalid_content_length") from exc
            if size < 0 or size > MAX_RESPONSE_BYTES:
                raise LibraryError("总备份超过 32 MiB 限制", "request_too_large", 413)
            body = self.rfile.read(size)
            if len(body) != size:
                raise LibraryError("总备份上传不完整，未覆盖云端稿件", "incomplete_request")
            self._send(200, encode_json(self.server.library.replace_backup(body)))
        except LibraryError as exc:
            self._error(exc)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except TimeoutError:
            self._error(LibraryError("总备份上传超时，未完成覆盖", "request_timeout", 408))
        except Exception:
            self._error(LibraryError("稿库暂时不可用，未完成上传", "internal_error", 500))

    def do_POST(self):
        try:
            if self._route() != "/api/v1/scripts/import-markdown":
                raise LibraryError("接口不存在", "not_found", 404)
            self._authorize(write=True)
            content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            if content_type not in ("text/markdown", "application/json"):
                raise LibraryError("上传类型必须为 text/markdown 或 application/json，内容使用 UTF-8", "unsupported_media_type", 415)
            lengths = self.headers.get_all("Content-Length", [])
            if self.headers.get("Transfer-Encoding") or len(lengths) != 1:
                raise LibraryError("上传必须携带唯一 Content-Length，不支持分块编码", "invalid_content_length", 411)
            try:
                size = int(lengths[0])
            except ValueError as exc:
                raise LibraryError("Content-Length 无效", "invalid_content_length") from exc
            if size < 0 or size > MAX_REQUEST_BYTES:
                raise LibraryError("文档超过 1 MiB 上传限制", "request_too_large", 413)
            body = self.rfile.read(size)
            if len(body) != size:
                raise LibraryError("文档上传不完整", "incomplete_request")
            if content_type == "application/json":
                try:
                    def unique_keys(pairs):
                        obj = {}
                        for key, value in pairs:
                            if key in obj:
                                raise ValueError("duplicate key")
                            obj[key] = value
                        return obj
                    document = json.loads(body.decode("utf-8"), object_pairs_hook=unique_keys)
                    if not isinstance(document, dict) or set(document) != {"markdown"} or not isinstance(document["markdown"], str):
                        raise ValueError("invalid schema")
                    body = document["markdown"].encode("utf-8")
                except (ValueError, UnicodeError, RecursionError):
                    raise LibraryError("JSON 必须且只能包含字符串字段 markdown", "invalid_json") from None
            result = self.server.library.import_markdown(body)
            self._send(201 if result["created"] else 200, encode_json(result))
        except LibraryError as exc:
            self._error(exc)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except TimeoutError:
            self._error(LibraryError("文档上传超时", "request_timeout", 408))
        except Exception:
            self._error(LibraryError("稿库暂时不可用，未完成上传", "internal_error", 500))

    def send_error(self, code, message=None, explain=None):
        self._error(LibraryError("不支持的请求或方法", "unsupported_request", code))


def load_token(name: str) -> str:
    filename = os.environ.get(name + "_FILE")
    if filename:
        return validate_token(Path(filename).read_text(encoding="utf-8").strip())
    return validate_token(os.environ.get(name, ""))


def main(argv=None):
    parser = argparse.ArgumentParser(description="私人提词稿库；监听本机，由 HTTPS 反向代理提供访问")
    parser.add_argument("--data-dir", default=os.environ.get("CLOUD_LIBRARY_DATA_DIR", "./data"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CLOUD_LIBRARY_PORT", "18431")))
    args = parser.parse_args(argv)
    server = LibraryHTTPServer(("127.0.0.1", args.port), Library(args.data_dir),
                               load_token("CLOUD_LIBRARY_READ_TOKEN"), load_token("CLOUD_LIBRARY_UPLOAD_TOKEN"))
    print(f"稿库已启动，仅监听 127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
