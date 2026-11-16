#!/usr/bin/env python3
"""按模板校验并上传 Markdown；不调用 AI，不读取或输出正文到日志。"""
from __future__ import annotations

import argparse
import ipaddress
import json
from pathlib import Path
import sys
from urllib import error, request
from urllib.parse import urlsplit, urlunsplit

try:
    from .app import LibraryError, MAX_REQUEST_BYTES, parse_markdown, validate_token
except ImportError:
    from app import LibraryError, MAX_REQUEST_BYTES, parse_markdown, validate_token


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward an Authorization header to a new host.


def import_url(base: str) -> str:
    parsed = urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("服务地址不能包含用户名、密码、查询参数或片段")
    hostname = parsed.hostname
    if not hostname:
        raise ValueError("请填写包含 https:// 的云稿库地址")
    loopback = hostname.lower() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        pass
    if parsed.scheme != "https" and not (parsed.scheme == "http" and loopback):
        raise ValueError("公网稿库必须使用 HTTPS；HTTP 只允许本机开发地址")
    if parsed.path and not parsed.path.startswith("/"):
        raise ValueError("服务地址路径无效")
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/") + "/api/v1/scripts/import-markdown", "", ""))


def prepare(paths: list[Path]) -> list[tuple[Path, str, bytes]]:
    entries = []
    ids = set()
    for path in paths:
        if path.stat().st_size > MAX_REQUEST_BYTES:
            raise ValueError(f"{path.name}：文档超过 1 MiB")
        raw = path.read_bytes()
        try:
            script_id, _, _ = parse_markdown(raw)
        except LibraryError as exc:
            raise ValueError(f"{path.name}：{exc.message}") from exc
        if script_id in ids:
            raise ValueError(f"本批文档出现重复脚本编号：{script_id}，请先处理重复文件")
        ids.add(script_id)
        entries.append((path, script_id, raw))
    return entries


def upload_one(endpoint: str, token: str, raw: bytes) -> dict:
    opener = request.build_opener(NoRedirect())
    req = request.Request(endpoint, data=raw, method="POST", headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "text/markdown; charset=utf-8",
        "Accept": "application/json",
    })
    try:
        with opener.open(req, timeout=30) as response:
            data = response.read(2 * MAX_REQUEST_BYTES)
            result = json.loads(data)
            if not isinstance(result, dict) or not isinstance(result.get("created"), bool):
                raise ValueError("服务端响应格式无效")
            return result
    except error.HTTPError as exc:
        # Do not print request objects, tokens, response bodies or redirect locations.
        if 300 <= exc.code < 400:
            raise ValueError("服务端要求重定向，已拒绝转发令牌；请使用最终的 HTTPS 地址") from None
        message = f"上传被拒绝（HTTP {exc.code}）"
        try:
            payload = json.loads(exc.read(16384))
            code = payload.get("error", {}).get("code", "")
            if isinstance(code, str) and len(code) <= 64 and code.isascii():
                message += "：" + code
        except (ValueError, AttributeError):
            pass
        raise ValueError(message) from None
    except (error.URLError, TimeoutError, OSError):
        raise ValueError("无法连接稿库，请检查网络、HTTPS 证书及服务地址") from None
    except (ValueError, TypeError):
        raise ValueError("服务端响应格式无效") from None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="校验并上传纯台词 Markdown；同编号更新，逐稿事务提交")
    parser.add_argument("--url", help="云稿库根地址，可包含部署前缀，例如 https://example.com/teleprompter")
    parser.add_argument("--token-file", type=Path, help="包含上传令牌的私密文件；不支持在参数直接填写令牌")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--file", type=Path)
    source.add_argument("--directory", type=Path, help="递归处理该目录中的 .md 文件")
    parser.add_argument("--dry-run", action="store_true", help="仅校验全部输入，不连接或修改云稿库")
    args = parser.parse_args(argv)
    try:
        paths = [args.file] if args.file else sorted(args.directory.rglob("*.md"))
        if not paths:
            raise ValueError("目录中没有 .md 文档")
        entries = prepare(paths)  # Validate the entire batch before the first network call.
        if args.dry_run:
            print(json.dumps({"dryRun": True, "validated": len(entries), "scriptIds": [e[1] for e in entries]}, ensure_ascii=False))
            return 0
        if not args.url or not args.token_file:
            raise ValueError("实际上传需要 --url 和 --token-file")
        endpoint = import_url(args.url)
        token = validate_token(args.token_file.read_text(encoding="utf-8").strip())
    except (ValueError, OSError) as exc:
        print(json.dumps({"ok": False, "uploaded": 0, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1
    results = []
    for path, script_id, raw in entries:
        try:
            result = upload_one(endpoint, token, raw)
            results.append({"file": path.name, "scriptId": script_id, "ok": True, "created": result["created"],
                            "revision": result.get("script", {}).get("revision")})
        except ValueError as exc:
            results.append({"file": path.name, "scriptId": script_id, "ok": False, "error": str(exc)})
            print(json.dumps({"ok": False, "uploaded": sum(r["ok"] for r in results), "total": len(entries),
                              "partialSuccess": any(r["ok"] for r in results), "results": results,
                              "message": "逐稿提交，失败前成功的稿件已经保存；后续稿件未上传。修复后可整批重试，相同正文不会重复新增。"}, ensure_ascii=False))
            return 2
    print(json.dumps({"ok": True, "uploaded": len(results), "results": results}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
