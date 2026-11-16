import concurrent.futures
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app
import test_server
from test_server import READ, WRITE, markdown


def backup(name="本机完整稿件", body="<p><strong>富文本</strong>台词</p>"):
    return {"format": "storm-cloud-backup", "version": 1,
            "createdAt": "2026-11-16T00:00:00Z",
            "articles": [{"id": name, "title": name, "content": body,
                          "createdAt": "2026-11-15T00:00:00Z", "updatedAt": "2026-11-16T00:00:00Z",
                          "sortOrder": 2, "folderId": "child"}],
            "folders": [{"id": "parent", "name": "父目录", "parentId": None,
                         "createdAt": "2026-11-15T00:00:00Z", "sortOrder": 0},
                        {"id": "child", "name": "子目录", "parentId": "parent",
                         "createdAt": "2026-11-15T00:00:00Z", "sortOrder": 1}]}


class FullBackupDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.library = app.Library(self.temp.name)

    def replace(self, doc):
        return self.library.replace_backup(app.encode_json(doc))

    def current(self):
        return json.loads(self.library.backup_bytes())

    def test_never_uploaded_is_distinct_from_intentionally_empty_backup(self):
        with self.assertRaises(app.LibraryError) as error:
            self.current()
        self.assertEqual(error.exception.code, "no_backup")
        empty = backup()
        empty["articles"] = []
        empty["folders"] = []
        self.replace(empty)
        self.assertEqual(self.current()["backup"], empty)

    def test_replaces_all_content_without_retaining_generations_and_persists(self):
        first, second = backup(), backup("另一个设备的稿件")
        self.assertEqual(self.replace(first)["revision"], 1)
        self.assertEqual(self.current()["backup"], first)
        self.assertEqual(self.replace(second)["revision"], 2)
        self.assertEqual(self.current()["backup"], second)
        restored = json.loads(app.Library(self.temp.name).backup_bytes())
        self.assertEqual(restored, self.current())
        with self.library.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM metadata WHERE key='content_backup'").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM scripts").fetchone()[0], 0)
        with self.assertRaises(app.LibraryError) as error:
            self.library.snapshot_bytes()
        self.assertEqual(error.exception.status, 426)

    def test_invalid_graph_duplicate_ids_settings_and_unicode_leave_current_unchanged(self):
        self.replace(backup())
        before = self.library.backup_bytes()
        cases = []
        for field, value in [("settings", {}), ("token", "secret")]:
            doc = backup(); doc[field] = value; cases.append(doc)
        doc = backup(); doc["articles"][0]["teleprompterSettings"] = {}; cases.append(doc)
        doc = backup(); doc["articles"].append(copy.deepcopy(doc["articles"][0])); cases.append(doc)
        doc = backup(); doc["folders"][0]["parentId"] = "child"; cases.append(doc)
        doc = backup(); doc["folders"][1]["parentId"] = "missing"; cases.append(doc)
        doc = backup(); doc["articles"][0]["folderId"] = []; cases.append(doc)
        doc = backup(); doc["articles"][0]["folderId"] = "missing"; cases.append(doc)
        doc = backup(); doc["articles"][0]["content"] = "bad\x00"; cases.append(doc)
        doc = backup(); doc["articles"][0]["sortOrder"] = True; cases.append(doc)
        doc = backup(); doc["articles"][0]["updatedAt"] = "2026-02-30T00:00:00Z"; cases.append(doc)
        doc = backup(); doc["articles"][0]["updatedAt"] = "2020-01-01T00:00:00Z"; cases.append(doc)
        for doc in cases:
            with self.subTest(doc=doc), self.assertRaises(app.LibraryError):
                self.replace(doc)
            self.assertEqual(self.library.backup_bytes(), before)
        for raw in [b'{"format":"x","format":"y"}', b'[]', b'null', b'\xff', b'{"a":NaN}']:
            with self.assertRaises(app.LibraryError):
                self.library.replace_backup(raw)
            self.assertEqual(self.library.backup_bytes(), before)

    def test_content_limits_and_utf16_are_checked_before_replace(self):
        self.replace(backup())
        before = self.library.backup_bytes()
        doc = backup(body="😀" * 200001)
        with self.assertRaises(app.LibraryError):
            self.replace(doc)
        self.assertEqual(self.library.backup_bytes(), before)

    def test_database_failure_rolls_back_metadata_and_legacy_cleanup(self):
        self.library.import_markdown(markdown())
        before = self.library.snapshot_bytes()
        with self.library.connect() as db:
            db.execute("CREATE TRIGGER fail_cleanup BEFORE DELETE ON scripts BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        with self.assertRaises(Exception):
            self.replace(backup())
        self.assertEqual(self.library.snapshot_bytes(), before)
        with self.library.connect() as db:
            self.assertIsNone(db.execute("SELECT value FROM metadata WHERE key='content_backup'").fetchone())

    def test_concurrent_uploads_have_one_complete_winner_and_unique_revisions(self):
        docs = [backup(f"设备{i}", f"<p>完整快照{i}</p>") for i in range(12)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(self.replace, docs))
        self.assertEqual(sorted(r["revision"] for r in results), list(range(1, 13)))
        winner = self.current()
        self.assertEqual(winner["revision"], 12)
        self.assertIn(winner["backup"], docs)
        self.assertEqual(len(winner["backup"]["articles"]), 1)

    def test_legacy_markdown_can_be_restored_without_changing_ids(self):
        self.library.import_markdown(markdown("001"))
        legacy = json.loads(self.library.snapshot_bytes())
        current = self.current()
        article = current["backup"]["articles"][0]
        self.assertEqual(article["id"], f'cloud:{legacy["libraryId"]}:001')
        self.assertEqual(article["title"], "001")
        self.replace(current["backup"])
        self.library.import_markdown(markdown("001", "更新正文"))
        updated = self.current()
        self.assertEqual(len(updated["backup"]["articles"]), 1)
        self.assertEqual(updated["backup"]["articles"][0]["id"], article["id"])
        self.assertNotIn("不要朗读", updated["backup"]["articles"][0]["content"])
        revision = updated["revision"]
        self.library.import_markdown(markdown("001", "更新正文", "另一个备注"))
        self.assertEqual(self.current()["revision"], revision)

    def test_markdown_updates_current_backup_and_preserves_other_content_and_folders(self):
        initial = backup()
        self.replace(initial)
        result = self.library.import_markdown(markdown("001", "GPT新稿"))
        self.assertTrue(result["created"])
        current = self.current()["backup"]
        self.assertEqual(current["folders"], initial["folders"])
        self.assertEqual(current["articles"][0], initial["articles"][0])
        self.assertEqual(current["articles"][1]["title"], "001")
        self.replace(initial)
        self.assertEqual(len(self.current()["backup"]["articles"]), 1)


class FullBackupHTTPTests(unittest.TestCase):
    setUp = test_server.HTTPTests.setUp
    close = test_server.HTTPTests.close
    call = test_server.HTTPTests.call
    def test_upload_download_permissions_and_current_snapshot(self):
        route = "/api/v1/backup"
        headers = {"Content-Type": "application/json"}
        self.assertEqual(self.call("GET", route)[0], 401)
        self.assertEqual(self.call("GET", route, READ)[0], 404)
        self.assertEqual(self.call("PUT", route, READ, app.encode_json(backup()), headers)[0], 403)
        status, result = self.call("PUT", route, WRITE, app.encode_json(backup()), headers)
        self.assertEqual(status, 200)
        self.assertEqual(result["articles"], 1)
        self.assertEqual(result["folders"], 2)
        for token in (READ, WRITE):
            status, result = self.call("GET", route, token)
            self.assertEqual(status, 200)
            self.assertEqual(result["backup"], backup())
        self.assertEqual(self.call("GET", route)[0], 401)

    def test_failed_http_upload_does_not_replace_existing_backup(self):
        route = "/api/v1/backup"
        headers = {"Content-Type": "application/json"}
        self.call("PUT", route, WRITE, app.encode_json(backup()), headers)
        before = self.library.backup_bytes()
        self.assertEqual(self.call("PUT", route, WRITE, b"{}", headers)[0], 400)
        self.assertEqual(self.call("PUT", route, WRITE, b"{}", {"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.call("PUT", route, WRITE, b"", {
            **headers, "Content-Length": str(app.MAX_RESPONSE_BYTES + 1)})[0], 413)
        self.assertEqual(self.library.backup_bytes(), before)
