import concurrent.futures
import contextlib
import http.client
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app
import upload

READ = "read-" + "r" * 48
WRITE = "upload-" + "w" * 48


def markdown(script_id="TC-001", body="你好，世界。", notes="不要朗读"):
    return f'---\nscript_id: "{script_id}"\n---\n\n## 正文\n\n{body}\n\n## 备注\n{notes}\n'.encode()


class ParserTests(unittest.TestCase):
    def test_preserves_id_and_paragraphs_ignores_notes(self):
        script_id, body, content = app.parse_markdown(markdown("001", "第一段\n继续\n\n第二段"))
        self.assertEqual(script_id, "001")
        self.assertEqual(body, "第一段\n继续\n\n第二段")
        self.assertEqual(content, "<p>第一段</p>\n<p>继续</p>\n<p></p>\n<p>第二段</p>")
        self.assertNotIn("不要朗读", body)

    def test_html_is_escaped_and_markdown_not_executed(self):
        _, body, content = app.parse_markdown(markdown(body='<script>alert("x")</script> **原样** &'))
        self.assertIn('**原样**', body)
        self.assertNotIn('<script>', content)
        self.assertIn('&lt;script&gt;', content)
        self.assertIn('alert("x")', content)
        self.assertIn('&amp;', content)

    def test_frontmatter_invalid_or_duplicate_rejected(self):
        cases = [x.encode() for x in ["## 正文\nx", "---\n---\n## 正文\nx",
                 "---\nscript_id: X\nscript_id: Y\n---\n## 正文\nx",
                 "---\nscript_id: X\ntitle: Y\n---\n## 正文\nx",
                 "---\nscript_id: X\n# comment\n---\n## 正文\nx",
                 "---\nscript_id: X\n---\n## Other\nx"]]
        cases += [markdown("../evil"), markdown("TC 001"), markdown("中文"), markdown("A" * 65),
                  markdown(body="  "), b"\xff", markdown(body="\x00")]
        for raw in cases:
            with self.subTest(raw=raw[:50]):
                with self.assertRaises(app.LibraryError):
                    app.parse_markdown(raw)

    def test_utf16_budget_and_normalized_line_endings(self):
        self.assertEqual(app.utf16_units("A😀中"), 4)
        self.assertEqual(app.parse_markdown(markdown(body="你好").replace(b"\n", b"\r\n"))[1], "你好")
        with self.assertRaises(app.LibraryError):
            app.parse_markdown(markdown(body="😀" * 25001))
        self.assertEqual(len(app.parse_markdown(markdown(body="😀" * 25000))[1]), 25000)
        with self.assertRaises(app.LibraryError):
            app.parse_markdown(b"x" * (app.MAX_REQUEST_BYTES + 1))

    def test_higher_heading_ends_body(self):
        raw = b'---\nscript_id: TC-001\n---\n## ' + '正文\n第一句\n### 小节\n第二句\n# 其他\n不导入'.encode()
        self.assertEqual(app.parse_markdown(raw)[1], "第一句\n### 小节\n第二句")


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.library = app.Library(self.temp.name)

    def snapshot(self):
        return json.loads(self.library.snapshot_bytes())

    def test_idempotent_update_preserves_library_and_creation(self):
        first = self.library.import_markdown(markdown())
        self.assertTrue(first["created"])
        self.assertEqual(first["script"]["title"], "TC-001")
        snapshot = self.snapshot()
        self.assertEqual(snapshot["revision"], 1)
        again = self.library.import_markdown(markdown(notes="新备注但正文相同"))
        self.assertFalse(again["created"])
        self.assertEqual(again["script"], first["script"])
        self.assertEqual(self.snapshot(), snapshot)
        update = self.library.import_markdown(markdown(body="新台词"))
        self.assertFalse(update["created"])
        self.assertEqual(update["script"]["revision"], 2)
        self.assertEqual(update["script"]["createdAt"], first["script"]["createdAt"])
        self.assertEqual(json.loads(app.Library(self.temp.name).snapshot_bytes())["libraryId"], snapshot["libraryId"])

    def test_bad_parse_and_budget_failure_leave_database_unchanged(self):
        self.library.import_markdown(markdown())
        before = self.library.snapshot_bytes()
        with self.assertRaises(app.LibraryError):
            self.library.import_markdown(markdown(body=""))
        for limit in ("MAX_SCRIPTS", "MAX_TOTAL_BODY_UNITS", "MAX_TOTAL_CONTENT_UNITS", "MAX_RESPONSE_BYTES"):
            with self.subTest(limit=limit), patch.object(app, limit, 1):
                with self.assertRaises(app.LibraryError):
                    self.library.import_markdown(markdown("TC-002", "正文"))
            self.assertEqual(self.library.snapshot_bytes(), before)
        with patch.object(app, "MAX_RESPONSE_BYTES", 1):
            with self.assertRaises(app.LibraryError):
                self.library.import_markdown(markdown(body="修改正文也回滚"))
        self.assertEqual(self.library.snapshot_bytes(), before)

    def test_concurrent_writes_keep_complete_unique_revisions(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda i: self.library.import_markdown(markdown(f"TC-{i:03d}")), range(24)))
        snapshot = self.snapshot()
        self.assertEqual(snapshot["revision"], 24)
        self.assertEqual(len(snapshot["scripts"]), 24)
        self.assertEqual(sorted(r["script"]["revision"] for r in results), list(range(1, 25)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: self.library.import_markdown(markdown("TC-000")), range(16)))
        self.assertEqual(self.snapshot()["revision"], 24)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.library = app.Library(self.temp.name)
        self.server = app.LibraryHTTPServer(("127.0.0.1", 0), self.library, READ, WRITE)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def call(self, method, path, token=None, body=None, headers=None):
        outgoing = dict(headers or {})
        if token:
            outgoing["Authorization"] = "Bearer " + token
        if body is not None:
            outgoing.setdefault("Content-Type", "text/markdown; charset=utf-8")
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            conn.request(method, path, body=body, headers=outgoing)
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def test_real_http_auth_health_read_and_write(self):
        self.assertEqual(self.call("GET", "/healthz"), (200, {"status": "ok"}))
        self.assertEqual(self.call("GET", "/api/v1/library")[0], 401)
        self.assertEqual(self.call("GET", "/api/v1/library", "wrong")[0], 401)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", READ, markdown())[0], 403)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, markdown())[0], 201)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, markdown())[0], 200)
        status, snapshot = self.call("GET", "/api/v1/library", READ)
        self.assertEqual(status, 200)
        self.assertEqual(snapshot["format"], app.FORMAT)
        self.assertEqual(snapshot["scripts"][0]["title"], "TC-001")
        self.assertEqual(self.call("GET", "/api/v1/library", WRITE)[0], 200)
        self.assertEqual(self.call("GET", "/api/v1/library?token=" + READ)[0], 400)
        self.assertEqual(self.call("GET", "/missing", READ)[0], 404)
        self.assertEqual(self.call("DELETE", "/api/v1/library", WRITE)[0], 501)

    def test_invalid_upload_limits_and_content_type(self):
        before = self.library.snapshot_bytes()
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, markdown(), {"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, b"invalid")[0], 400)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, b"", {"Content-Length": str(app.MAX_REQUEST_BYTES + 1)})[0], 413)
        self.assertEqual(self.library.snapshot_bytes(), before)

    def test_json_actions_upload_reuses_markdown_parser_and_is_idempotent(self):
        headers = {"Content-Type": "application/json"}
        payload = json.dumps({"markdown": markdown("001", "GPT整理后的正文").decode()}, ensure_ascii=False).encode()
        status, result = self.call("POST", "/api/v1/scripts/import-markdown", WRITE, payload, headers)
        self.assertEqual(status, 201)
        self.assertEqual(result["script"]["scriptId"], "001")
        self.assertEqual(result["script"]["body"], "GPT整理后的正文")
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, payload, headers)[0], 200)
        self.assertEqual(json.loads(self.library.snapshot_bytes())["revision"], 1)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", READ, payload, headers)[0], 403)

    def test_invalid_json_schema_or_utf8_does_not_write(self):
        headers = {"Content-Type": "application/json"}
        before = self.library.snapshot_bytes()
        cases = [b"{", b"[]", b"null", b'{}', b'{"markdown":123}',
                 b'{"markdown":"x","token":"bad"}', b'{"markdown":"x","markdown":"y"}',
                 b'{"markdown":"\\ud800"}', b"\xff", json.dumps({"markdown": "bad markdown"}).encode()]
        for raw in cases:
            with self.subTest(raw=raw):
                self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, raw, headers)[0], 400)
                self.assertEqual(self.library.snapshot_bytes(), before)
        self.assertEqual(self.call("POST", "/api/v1/scripts/import-markdown", WRITE, b"", {
            **headers, "Content-Length": str(app.MAX_REQUEST_BYTES + 1)})[0], 413)
        self.assertEqual(self.library.snapshot_bytes(), before)

    def test_upload_cli_actual_request_dry_run_and_batch_preflight(self):
        docs = Path(self.temp.name) / "docs"
        docs.mkdir()
        token_file = Path(self.temp.name) / "upload-token"
        token_file.write_text(WRITE)
        token_file.chmod(0o600)
        first = docs / "001.md"
        first.write_bytes(markdown("001"))
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            code = upload.main(["--file", str(first), "--dry-run"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout.getvalue())["scriptIds"], ["001"])
        self.assertEqual(json.loads(self.library.snapshot_bytes())["revision"], 0)
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            code = upload.main(["--file", str(first), "--url", self.base, "--token-file", str(token_file)])
        self.assertEqual(code, 0)
        self.assertNotIn(WRITE, stdout.getvalue())
        self.assertEqual(json.loads(self.library.snapshot_bytes())["revision"], 1)
        second = docs / "002.md"
        second.write_bytes(markdown("002", body=""))
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            code = upload.main(["--directory", str(docs), "--url", self.base, "--token-file", str(token_file)])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(self.library.snapshot_bytes())["revision"], 1)
        second.write_bytes(markdown("001"))
        with self.assertRaises(ValueError):
            upload.prepare([first, second])

    def test_cli_partial_success_is_explicit(self):
        docs = Path(self.temp.name) / "batch"
        docs.mkdir()
        (docs / "001.md").write_bytes(markdown("001"))
        (docs / "002.md").write_bytes(markdown("002"))
        token_file = Path(self.temp.name) / "token"
        token_file.write_text(WRITE)
        real_upload = upload.upload_one
        def fail_second(endpoint, token, raw):
            if app.parse_markdown(raw)[0] == "002":
                raise ValueError("模拟网络失败")
            return real_upload(endpoint, token, raw)
        with patch.object(upload, "upload_one", fail_second), contextlib.redirect_stdout(io.StringIO()) as stdout:
            code = upload.main(["--directory", str(docs), "--url", self.base, "--token-file", str(token_file)])
        report = json.loads(stdout.getvalue())
        self.assertEqual(code, 2)
        self.assertTrue(report["partialSuccess"])
        self.assertEqual(report["uploaded"], 1)
        self.assertEqual(len(json.loads(self.library.snapshot_bytes())["scripts"]), 1)

    def test_log_omits_paths_tokens_and_bodies(self):
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.call("GET", "/healthz?token=" + WRITE)
            self.call("POST", "/api/v1/scripts/import-markdown", WRITE, markdown(body="私密台词"))
        self.assertEqual(stderr.getvalue(), "")


class ConfigurationTests(unittest.TestCase):
    def test_tokens_must_be_distinct_and_long(self):
        with tempfile.TemporaryDirectory() as directory:
            library = app.Library(directory)
            for read, write in [("short", WRITE), (READ, READ), (READ, "x" * 31)]:
                with self.subTest(read=read[:5]), self.assertRaises(ValueError):
                    app.LibraryHTTPServer(("127.0.0.1", 0), library, read, write)

    def test_url_preserves_prefix_and_rejects_credentials(self):
        self.assertEqual(upload.import_url("https://note.example/teleprompter/"), "https://note.example/teleprompter/api/v1/scripts/import-markdown")
        for url in ["http://public.example", "https://user:secret@example.com", "https://example.com/?token=x", "https://example.com/#x"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                upload.import_url(url)


if __name__ == "__main__":
    unittest.main()
