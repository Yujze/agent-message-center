from pathlib import Path
import os
import time
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing

from codex_local_sessions import session_snapshot, desktop_snapshot, qoder_catalog, dsh_catalog


class CodexLocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.folder = r"C:\demo\待我接手"
        self.a = "11111111-1111-4111-8111-111111111111"
        self.b = "22222222-2222-4222-8222-222222222222"
        path, extended = self.folder, "\\\\?\\" + self.folder
        self.c = "66666666-6666-4666-8666-666666666666"
        records = [
            (self.a, 101, "A", path, "Codex Desktop", "user", 0),
            (self.b, 100, "B", extended, "Codex Desktop", None, 0),
            ("33333333-3333-4333-8333-333333333333", 105, "CLI", path, "exec", "user", 0),
            ("44444444-4444-4444-8444-444444444444", 105, "", path, "Codex Desktop", "subagent", 0),
            ("55555555-5555-4555-8555-555555555555", 105, "", path, "Codex Desktop", "user", 1),
            (self.c, 105, "C", path + "2", "codex_work_desktop", "user", 0),
            ("invalid", 105, "", path, "Codex Desktop", "user", 0),
        ]
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("create table threads (id, updated_at, name, cwd, originator, thread_source, archived, source default 'vscode')")
            db.executemany("insert into threads (id,updated_at,name,cwd,originator,thread_source,archived) values (?,?,?,?,?,?,?)", records)
            db.execute("update threads set source='exec' where originator='exec'")
            db.execute("update threads set source='subagent' where thread_source='subagent'")
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("create table thread_turns (thread_id, rollout_ordinal, status)")
            db.executemany("insert into thread_turns values (?,?,?)",
                           [(self.a, 1, "completed"), (self.a, 2, "inProgress"), (self.b, 9, "interrupted"), (self.c, 1, "completed")])
            db.commit()

    def test_all_projects_and_legacy_desktop_client(self):
        rows = session_snapshot(self.home)["sessions"]
        self.assertEqual([(r["id"], r["turn"]) for r in rows],
                         [(self.c, "completed"), (self.a, "inProgress"), (self.b, "interrupted")])

    def test_attached_codex_chats_resolve_to_live_main_conversation(self):
        def snapshot():
            return {r["id"]:r for r in session_snapshot(self.home)["sessions"]}
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("alter table threads add column attached_thread_parent_id text")
            db.executemany("update threads set attached_thread_parent_id=? where id=?",
                           [(self.a, self.b), (self.b, self.c)])
            db.commit()
            rows = snapshot()
            self.assertNotIn("parentId", rows[self.a])
            self.assertEqual((rows[self.b]["rootId"], rows[self.c]["rootId"]), (self.a, self.a))
            self.assertEqual(rows[self.c]["parentId"], self.b)
            long_title = "重复前缀" * 23 + "  精确的后缀"
            db.execute("update threads set name=? where id=?", (long_title, self.b))
            db.commit()
            side = snapshot()[self.b]
            self.assertEqual(side["desktopTitle"], long_title)
            self.assertEqual(side["name"], long_title[:80])
            db.execute("update threads set attached_thread_parent_id=? where id=?", (self.c, self.a))
            db.commit()
            self.assertTrue(all(row["rootId"] is None for row in snapshot().values()))
            db.execute("update threads set attached_thread_parent_id=null,archived=1 where id=?", (self.a,))
            db.commit()
            self.assertIsNone(snapshot()[self.c]["rootId"])
            db.execute("delete from threads where id=?", (self.a,))
            db.commit()
            self.assertIsNone(snapshot()[self.b]["rootId"])

    def test_missing_history_only_removes_turn_status(self):
        (self.home / "thread_history_1.sqlite").unlink()
        snapshot = session_snapshot(self.home)
        rows = snapshot["sessions"]
        self.assertEqual([r["turn"] for r in rows], ["unknown"] * 3)
        self.assertEqual(snapshot["summary"], {"total": 3, "running": None, "completed": None})
        self.assertFalse((self.home / "thread_history_1.sqlite").exists())

    def test_project_counts_include_older_sessions_and_only_latest_turn(self):
        older = [f"11111111-2222-4444-8888-{i:012d}" for i in range(16)]
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.executemany("insert into threads values (?,90,'',?,'Codex Desktop','user',0,'vscode')",
                           [(thread_id, self.folder) for thread_id in older])
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.executemany("insert into thread_turns values (?,1,'completed')", [(thread_id,) for thread_id in older])
            db.commit()
        snapshot = session_snapshot(self.home)
        self.assertEqual(len(snapshot["sessions"]), 19)
        self.assertEqual(snapshot["summary"], {"total": 19, "running": 1, "completed": 17})
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("insert into thread_turns values (?,3,'completed')", (self.a,))
            db.commit()
        self.assertEqual(session_snapshot(self.home)["summary"], {"total": 19, "running": 0, "completed": 18})

    def test_all_sources_keep_separate_identities_and_message_times(self):
        now = int(time.time() * 1000)
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("alter table threads add column created_at_ms integer")
            db.execute("update threads set created_at_ms = ?", (now - 1000,))
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("create table thread_items(thread_id,rollout_ordinal,item_type,created_at_ms,completed_at_ms)")
            db.executemany("insert into thread_items values(?,?,?,?,?)", [
                (self.a, 1, "userMessage", now-400, None), (self.a, 2, "agentMessage", now-200, now-100),
                (self.a, 3, "commandExecution", now, now)])
            db.commit()
        roaming = self.home / "roaming"
        q = roaming / "Qoder/SharedClientCache/cache/db/local.db"
        q.parent.mkdir(parents=True)
        with closing(sqlite3.connect(q)) as db:
            db.execute("create table chat_session(session_id,session_title,gmt_create,last_user_query_at,session_type,parent_session_id)")
            db.execute("create table chat_message(session_id,role,gmt_create)")
            db.executemany("insert into chat_session values(?,?,?,?,?,?)", [
                (self.a, "Q", now-1000, now-500, "assistant", ""), ("child", "x", now, now, "quest", self.a)])
            db.executemany("insert into chat_message values(?,?,?)", [(self.a,"assistant",now-50),(self.a,"tool",now)])
            db.commit()
        d = self.home / "dsh/storages"
        records = d / "session_projcache/sessions"; records.mkdir(parents=True)
        (d / "workspace.json").write_text(json.dumps({"tables":{"workspaces":{
            "p":{"sessionIds":[self.a,"archived"]},"q":{"sessionIds":[self.a]}}},
            "global":{"archivedSessionIds":["archived"]}}))
        (records / (self.a + ".json")).write_text(json.dumps({"record":{"identity":{"createdAt":now-1000},
            "rows":{"title":{"val":"D"},"sessionListMetadata":{"val":{"blank":False,"lastPromptAt":now-500}},
                    "timeContext":{"val":{"lastMessageTime":now-10}}}}}))
        snap = desktop_snapshot(self.home, d.parent, roaming)
        shared = {r["agent"]: r["message"] for r in snap["sessions"] if r["id"] == self.a}
        self.assertEqual(shared, {"Codex": now-100, "Qoder":now-50, "DSH":now-10})
        self.assertEqual(snap["summary"]["total"], 5)
        self.assertTrue(snap["summary"]["partial"])
        projection = records / (self.a + ".json")
        data = json.loads(projection.read_bytes())
        meta = data["record"]["rows"]
        meta["turnBoundary"] = {"val":{"openTurnStartSeq":74}}
        meta["userQuestions"] = {"val":{"questions":{"active":[{"state":"open"},{"state":"open"}]}}}
        projection.write_text(json.dumps(data))
        def dsh_row():
            return next(s for s in desktop_snapshot(self.home,d.parent,roaming)["sessions"] if s["agent"] == "DSH")
        self.assertEqual((dsh_row()["turn"],dsh_row()["needsInput"]),("inProgress",1))
        meta["turnBoundary"]["val"]["openTurnStartSeq"] = None
        meta["userQuestions"]["val"]["questions"]["active"] = [{"state":"continued"}]
        projection.write_text(json.dumps(data))
        self.assertEqual((dsh_row()["turn"],dsh_row()["needsInput"]),("idle",0))
        with closing(sqlite3.connect(q)) as db:
            db.execute("drop table chat_message")
        recovered = desktop_snapshot(self.home, d.parent, roaming)
        self.assertEqual(recovered["sources"], {"Codex":"ready", "DSH":"ready", "Qoder":"unavailable"})
        self.assertEqual(recovered["summary"]["total"], 4)

    def test_dsh_lifecycle_and_catalog_recovery(self):
        index = self.home / "dsh/storages/workspace.json"
        directory = index.parent / "session_projcache/sessions"
        directory.mkdir(parents=True)
        index.write_text(json.dumps({"tables":{"workspaces":{"one":{"sessionIds":["active", self.b]}}},
                                     "global":{"archivedSessionIds":[self.b]}}))
        old = int(time.time()) - 7200

        def save(ident, boundary, active=(), **extra):
            rows = dict(title={"val":ident}, turnBoundary={"val":boundary},
                        userQuestions={"val":{"questions":{"active":active}}},
                        timeContext={"val":{"lastMessageTime":old * 1000}})
            rows.update(extra)
            path = directory / (ident + ".json")
            path.write_text(json.dumps({"record":{"rows":rows}}))
            return path

        def current():
            rows, status = dsh_catalog(index)
            return {row["id"]:row for row in rows}, status

        closed = {"openTurnStartSeq":None, "lastTurn":1}
        opened = {"openTurnStartSeq":80, "lastTurn":2}
        save("active", closed, [{"state":"open"}])
        save("outside", closed)
        save("blank", closed, sessionListMetadata={"val":{"blank":True}})
        save("child", closed, subagent={"val":{"identity":{"mode":"child"}}})
        save("session-" + self.b, closed)
        broken = directory / "broken.json"
        broken.write_text("{")
        rows, status = current()
        self.assertEqual((set(rows),status), ({"active","outside"},"partial"))
        self.assertEqual((rows["active"]["turn"],rows["active"]["needsInput"],rows["active"]["finished"]),
                         ("completed",0,old*1000))
        self.assertFalse(rows["active"].get("unread"))
        broken.unlink()
        self.assertEqual(current()[1],"ready")
        path = save("active", opened, [{"state":"continued"}])
        self.assertEqual(current()[0]["active"]["turn"],"inProgress")
        os.utime(path, (old,old))
        self.assertEqual(current()[0]["active"]["turn"],"unknown")
        path = save("active", opened, [{"state":"open"}])
        os.utime(path, (old,old))
        self.assertEqual(current()[0]["active"]["needsInput"],1)
        save("active", {"lastTurn":3}, [{"state":"open"}])
        self.assertEqual(current()[0]["active"]["turn"],"completed")
        self.assertEqual(current()[0]["active"]["needsInput"],0)
        index.write_text("{")
        self.assertEqual(current(), ({},"unavailable"))
        index.unlink()
        self.assertEqual(current()[1],"partial")
        self.assertIn("outside",current()[0])

    def test_qoder_recent_activity_from_both_desktop_catalogs(self):
        day = 86400000
        now = int(time.time() * 1000)
        old = now - 9 * day
        recent = now - 1500
        app = self.home / "com.qoder.app.stable/main.sqlite"
        app.parent.mkdir()
        with closing(sqlite3.connect(app)) as db:
            db.execute("""create table chat_sessions(session_id, title, created_at, updated_at, session_kind,
                                                     archived, archived_at, deleted_at)""")
            db.executemany("insert into chat_sessions values (?,?,?,?,?,?,?,?)", [
                ("recent","月报",old,old,"standard",0,None,None),
                ("metadata","侧栏更新",old,recent,"standard",0,None,None),
                ("old","旧消息",old,old,"standard",0,None,None),
                ("shared","应用中的名称",old,recent,"standard",0,None,None),
                ("archived","归档",old,recent,"standard",1,None,None),
                ("deleted","删除",old,recent,"standard",0,None,recent),
                ("child","旁支",old,recent,"sideChat",0,None,None),
                ("auto","执行",old,recent,"automationExecution",0,None,None)])
            db.execute("create table chat_session_messages(session_id, role, has_visible_content, created_at, updated_at)")
            db.executemany("insert into chat_session_messages values (?,?,?,?,?)", [
                ("recent","assistant",1,old,recent), ("metadata","user",1,old,old),
                ("old","system",1,now,now), ("old","assistant",0,now,now)])
            db.commit()
        def read():
            batch, status = qoder_catalog(self.home)
            return {row["id"]:row for row in batch}, status
        rows, status = read()
        self.assertEqual(status, "ready")  # standalone installation
        self.assertEqual(set(rows), {"recent","metadata","old","shared"})
        self.assertEqual(rows["recent"]["message"], recent)
        self.assertEqual(rows["metadata"]["message"], old)
        self.assertEqual(rows["old"]["activity"], old)
        self.assertIsNone(rows["old"]["message"])
        self.assertEqual({k for k,r in rows.items() if r["activity"] >= now-day},
                         {"recent","metadata","shared"})
        ide = self.home / "Qoder/SharedClientCache/cache/db/local.db"
        ide.parent.mkdir(parents=True)
        with closing(sqlite3.connect(ide)) as db:
            db.execute("create table chat_session(session_id,session_title,gmt_create,last_user_query_at,session_type,parent_session_id)")
            db.execute("create table chat_message(session_id,role,gmt_create)")
            db.executemany("insert into chat_session values(?,?,?,?,?,?)", [
                ("shared","旧名称",old-100,old,"assistant",""), ("ide","IDE",now,now,"assistant","")])
            db.commit()
        rows, status = read()
        self.assertEqual((len(rows),status), (5,"ready"))
        self.assertTrue(rows["shared"]["desktop"])
        self.assertFalse(rows["ide"].get("desktop"))
        self.assertEqual((rows["shared"]["name"],rows["shared"]["created"],rows["shared"]["activity"],rows["shared"]["message"]),
                         ("应用中的名称",old-100,recent,old))
        with closing(sqlite3.connect(app)) as db:
            db.execute("drop table chat_session_messages")  # older catalog without message metadata
        rows, status = read()
        self.assertEqual((rows["metadata"]["activity"],rows["metadata"]["message"],status),(recent,None,"ready"))
        with closing(sqlite3.connect(ide)) as db:
            db.execute("drop table chat_session")
        rows, status = read()
        self.assertEqual((len(rows),status),(4,"partial"))
        self.assertIn("recent",rows)

    def test_local_ui(self):
        if os.name != "nt":
            self.skipTest("Windows Forms")
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("alter table threads add column created_at integer")
            db.execute("update threads set created_at=updated_at+?", (int(time.time())-200,))
            db.commit()
        script = Path(__file__).with_name("Start-Reminder.ps1")
        env = {**os.environ, "CODEX_HOME": str(self.home)}
        subprocess.run(["pwsh", "-NoProfile", "-STA", "-File", str(script),
                        "-UiTest", "-CodexLocal"], env=env, check=True, timeout=30)

    def test_codex_completion_receipt_and_current_question(self):
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("create table thread_read_receipts(thread_id primary key,first_unread_turn)")
            db.execute("insert into thread_read_receipts values(?,?)",(self.c,"new"))
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("alter table thread_turns add column turn_id")
            db.execute("alter table thread_turns add column completed_at")
            db.execute("update thread_turns set turn_id='new',completed_at=1234 where status='completed'")
            db.execute("update thread_turns set turn_id='active' where status='inProgress'")
            for table in ("thread_items","thread_realtime_items"):
                db.execute(f"create table {table}(thread_id,turn_id,item_id,item_type,item_json,rollout_ordinal,updated_at_ordinal)")
            def question(table, turn, seq, status):
                db.execute(f"insert into {table} values(?,?,?,'dynamicToolCall',?,?,?)",(
                    self.a,turn,'call',json.dumps(dict(tool='request_user_input',status=status)),1,seq))
            question("thread_items","active",2,"inProgress")
            question("thread_items","previous",9,"inProgress")
            db.commit()
            def rows():
                return {r["id"]:r for r in session_snapshot(self.home)["sessions"]}
            snapshot=rows()
            self.assertEqual((snapshot[self.c]["finished"],snapshot[self.c]["unread"]),(1234000,1))
            self.assertIsNone(snapshot[self.b]["unread"])
            self.assertEqual(snapshot[self.a]["needsInput"],1)
            question("thread_realtime_items","active",3,"completed")
            db.commit()
            self.assertFalse(rows()[self.a]["needsInput"])
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("update thread_read_receipts set first_unread_turn=null")
            db.commit()
        self.assertEqual(rows()[self.c]["unread"],0)

    def test_unread_completion_when_history_refers_to_an_older_rollout(self):
        log = self.home / "rollout-current.jsonl"
        def append(kind, **fields):
            record = {"type":"event_msg", "timestamp":"2025-01-01T00:00:00.125Z",
                      "payload":{"type":kind, **fields}}
            with log.open("ab") as stream:
                stream.write(json.dumps(record).encode() + b"\n")
        def current():
            return next(r for r in session_snapshot(self.home)["sessions"] if r["id"] == self.b)
        def header(ident):
            log.write_text(json.dumps({"type":"session_meta","payload":{"id":ident}})+"\n",encoding="utf-8")
        stamp = 1735689600125
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("alter table threads add column rollout_path")
            db.execute("update threads set rollout_path=? where id=?", (str(log),self.b))
            db.execute("create table thread_read_receipts(thread_id,first_unread_turn,last_published_turn)")
            db.execute("insert into thread_read_receipts values(?,'first','latest')", (self.b,))
            db.commit()
            header(self.b)
            append("task_complete", turn_id="latest", last_agent_message="fixture")
            row=current()
            self.assertEqual((row["turn"],row["unread"],row["finished"],row["message"],row["activity"]),
                             ("completed",1,stamp,stamp,stamp))
            db.execute("update thread_read_receipts set first_unread_turn=NULL")
            db.commit()
            self.assertEqual((current()["turn"],current()["unread"]),("completed",0))
            append("task_started", turn_id="newer")
            self.assertIsNone(current()["finished"])
            append("turn_aborted", turn_id="newer")
            self.assertIsNone(current()["finished"])
            append("task_complete", turn_id="some-other-turn")
            self.assertIsNone(current()["finished"])
            header(self.a)
            append("task_complete", turn_id="latest")
            self.assertIsNone(current()["finished"])
            header(self.b)
            append("task_complete", turn_id="latest")
            with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as history:
                history.execute("alter table thread_turns add column started_at")
                history.execute("update thread_turns set started_at=? where thread_id=?", (stamp//1000+1,self.b))
                history.commit()
            self.assertEqual(current()["turn"],"interrupted")

    def test_parallel_turns_when_one_history_cursor_points_into_an_old_rollout(self):
        log = self.home / "current.jsonl"
        def append(record, payload):
            with log.open("ab") as stream:
                entry = dict(timestamp="2025-01-01T00:00:00.125Z", type=record, payload=payload)
                stream.write(json.dumps(entry).encode() + b"\n")

        def check(expected, running, waiting=None):
            snapshot = session_snapshot(self.home)
            active = [r["id"] for r in snapshot["sessions"] if r["turn"] == "inProgress" and not r["needsInput"]]
            row = next(r for r in snapshot["sessions"] if r["id"] == self.b)
            self.assertCountEqual(active, running)
            self.assertEqual(snapshot["summary"]["running"], len(running))
            self.assertEqual((row["turn"], row["needsInput"]), (expected, waiting))
            return row

        append("session_meta", {"id": self.b})
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("alter table threads add column rollout_path")
            db.execute("update threads set rollout_path=? where id=?", (str(log), self.b))
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("create table thread_history_projection_state(thread_id primary key,next_rollout_byte_offset)")
            db.execute("insert into thread_history_projection_state values(?,?)", (self.b, 3000000))
            db.execute("alter table thread_turns add column started_at")
            db.execute("update thread_turns set started_at=100 where thread_id=?", (self.b,))
            db.commit()
            append("event_msg", {"type": "task_started", "turn_id": "new"})
            append("response_item", {"type": "function_call_output", "output": "x" * 1100000})
            row = check("inProgress", [self.a, self.b])
            self.assertEqual((row["activity"], row["finished"], row["message"]), (1735689600125, None, None))
            append("response_item", {"type": "function_call", "name": "request_user_input", "call_id": "ask"})
            check("inProgress", [self.a], waiting=1)
            append("response_item", {"type": "function_call_output", "call_id": "ask"})
            check("inProgress", [self.a, self.b])
            with log.open("ab") as stream:
                stream.write(b'{"type":"event_msg","timestamp":"2025-01-01T00:01:00Z","payload":')
            check("inProgress", [self.a, self.b])
            with log.open("ab") as stream:
                stream.write(b'{"type":"task_complete","turn_id":"new"}}\n')
            self.assertEqual(check("completed", [self.a])["finished"], 1735689660000)

            # The projection has caught up and remains authoritative at EOF.
            db.execute("update thread_history_projection_state set next_rollout_byte_offset=?", (log.stat().st_size,))
            db.execute("update thread_turns set status='completed' where thread_id=?", (self.b,))
            db.commit()
            check("completed", [self.a])
            append("event_msg", {"type": "task_started", "turn_id": "next"})
            check("inProgress", [self.a, self.b])
            append("event_msg", {"type": "turn_aborted", "turn_id": "next"})
            check("interrupted", [self.a])

    def test_desktop_unread_only_uses_unambiguous_local_scope(self):
        def unread():
            return next(r["unread"] for r in session_snapshot(self.home)["sessions"] if r["id"]==self.c)
        with closing(sqlite3.connect(self.home / ".codex-global-state.sqlite")) as db:
            db.execute("create table settings(scope,key,value)")
            def set_state(scopes):
                value={"version":1,"unreadByIdentity":scopes,
                       "legacyMigration":{"unreadThreadIdsByHostId":{"local":[self.c]}}}
                db.execute("delete from settings")
                db.execute("insert into settings values('global','electron-thread-read-state-v1',?)",(json.dumps(value),))
                db.commit()
            set_state({"account":{"local:one":[self.c]}})
            self.assertEqual(unread(),1)
            set_state({"account":{"local:one":[],"remote:two":[self.c]}})
            self.assertIsNone(unread())
            set_state({"account":{"local:one":[self.c],"local:two":[]}})
            self.assertIsNone(unread())
            set_state({"account":{"local:one":[self.c]},"another":{"local:one":[]}})
            self.assertIsNone(unread())

    def test_plan_questions_from_the_active_rollout(self):
        log = self.home / "rollout-test.jsonl"

        def append(record, kind, **fields):
            with log.open("ab") as stream:
                line = {"type": record, "payload": {"type": kind, **fields}}
                stream.write(json.dumps(line).encode() + b"\n")

        def ask(call):
            append("response_item", "function_call", name="request_user_input", call_id=call, status="completed")

        def check(waiting):
            snapshot = session_snapshot(self.home)
            row = next(r for r in snapshot["sessions"] if r["id"] == self.a)
            self.assertEqual(bool(row["needsInput"]), waiting)
            self.assertEqual(snapshot["summary"]["running"], 0 if waiting else 1)

        append("event_msg", "task_started", turn_id="previous")
        ask("old")
        offset = log.stat().st_size
        append("event_msg", "task_started", turn_id="active", collaboration_mode_kind="plan")
        with closing(sqlite3.connect(self.home / "state_5.sqlite")) as db:
            db.execute("alter table threads add column rollout_path")
            db.execute("update threads set rollout_path=? where id=?", (str(log), self.a))
            db.commit()
        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("alter table thread_turns add column turn_id")
            db.execute("alter table thread_turns add column rollout_byte_offset integer")
            db.execute("update thread_turns set turn_id='active', rollout_byte_offset=? where status='inProgress'", (offset,))
            db.commit()
        check(False)
        append("response_item", "message", role="user", text="request_user_input")
        check(False)
        ask("first")
        check(True)
        append("response_item", "function_call_output", call_id="first")
        check(False)
        ask("second")
        ask("third")
        append("response_item", "function_call_output", call_id="old")
        append("response_item", "function_call_output", call_id="second")
        with log.open("ab") as stream:
            stream.write(b'{"type":"response_item","payload":{"type":"function_call_output",')
        check(True)
        with log.open("ab") as stream:
            stream.write(b'"call_id":"third"}}\n')
        check(False)
        ask("outstanding")
        append("event_msg", "turn_aborted", turn_id="active")
        check(False)
        log.unlink()
        append("event_msg", "task_started", turn_id="different")
        ask("other-turn-question")
        check(False)
        log.unlink()
        check(False)

    def test_codex_async_questions_match_individual_replies(self):
        def row():
            return next(r for r in session_snapshot(self.home)["sessions"] if r["id"] == self.a)

        with closing(sqlite3.connect(self.home / "thread_history_1.sqlite")) as db:
            db.execute("alter table thread_turns add column turn_id")
            db.execute("update thread_turns set turn_id='active' where status='inProgress'")
            db.execute("create table thread_items(thread_id,turn_id,item_id,item_type,item_json,rollout_ordinal)")
            def put(seq, kind, content, item=None, turn="active"):
                db.execute("insert into thread_items values(?,?,?,?,?,?)",
                           (self.a, turn, item or str(seq), kind, json.dumps(content), seq))
                db.commit()
            def reply(seq, *refs):
                payload = [{"questionItemId":json.dumps(["request_user_input_async", call, n]), "answer":"ok"}
                           for call, n in refs]
                put(seq, "userMessage", {"content":[{"type":"text","text":"<send_user_message_question_reply>\n"
                    + json.dumps(payload) + "\n</send_user_message_question_reply>"}]})
            question = {"delivery":"async","questions":[{"title":"one"},{"title":"two"}]}
            put(1,"agentMessage",question,"stale","earlier")
            reply(2,("call-a",0))
            put(3,"agentMessage",question,"call-a")
            self.assertTrue(row()["needsInput"])
            put(4,"userMessage",{"content":[{"type":"text","text":"ordinary reply"}]})
            put(5,"userMessage",{"content":[{"type":"text","text":"<send_user_message_question_reply>bad</send_user_message_question_reply>"}]})
            reply(6,("call-b",0),("call-a",3))
            reply(7,("call-a",1))
            self.assertTrue(row()["needsInput"])
            put(8,"agentMessage",{"delivery":"async","questions":[{"title":"three"}]},"call-b")
            reply(9,("call-a",0))
            self.assertTrue(row()["needsInput"])
            ref = json.dumps(["request_user_input_async","call-b",0])
            for seq, payload in enumerate(([{"questionItemId":ref}], {"fake":{"questionItemId":ref,"answer":"x"}}), start=10):
                put(seq,"userMessage",{"content":[{"type":"text","text":"<send_user_message_question_reply>"
                    + json.dumps(payload) + "</send_user_message_question_reply>"}]})
                self.assertTrue(row()["needsInput"])
            reply(12,("call-b",0))
            self.assertFalse(row()["needsInput"])
            put(13,"agentMessage",question,"call-c")
            db.execute("update thread_turns set status='interrupted' where turn_id='active'")
            db.commit()
            self.assertFalse(row()["needsInput"])

    def test_qoder_unread_follows_latest_turn(self):
        app = self.home / "com.qoder.app.stable/main.sqlite"
        app.parent.mkdir()
        with closing(sqlite3.connect(app)) as db:
            db.execute("create table chat_sessions(session_id,title,created_at,updated_at,session_kind,archived,archived_at,deleted_at,unread)")
            db.execute("insert into chat_sessions values('s','fixture',1,100,'standard',0,null,null,1)")
            db.execute("create table chat_session_messages(session_id,message_id,turn_id,sequence,role,status,created_at,updated_at,source)")
            db.execute("insert into chat_session_messages values('s','1','t1',1,'assistant','completed',1,20,'local')")
            db.commit()
            def session():
                return qoder_catalog(self.home)[0][0]
            self.assertEqual((session()["turn"],session()["finished"],session()["unread"]),("completed",20,1))
            db.execute("insert into chat_session_messages values('s','2','t2',2,'user','completed',50,50,'local')")
            db.commit()
            self.assertEqual((session()["turn"],session()["finished"]),("unknown",None))
            buffer = app.with_name("chat-session-turn-payload-buffer.sqlite")
            self.assertFalse(buffer.exists())
            with closing(sqlite3.connect(buffer)) as staging:
                staging.execute("create table active_turn_projection_items(session_id,turn_id,created_at)")
                staging.execute("create table pending_turn_projections(session_id,turn_id)")
                staging.executemany("insert into active_turn_projection_items values(?,?,?)",
                    [("s","t1",5),("other","t2",6),("s","t2",51),("s","t2",52)])
                staging.commit()
                self.assertEqual(session()["bufferedSince"],51)
                staging.execute("insert into pending_turn_projections values('s','t2')")
                staging.commit()
                self.assertNotIn("bufferedSince",session())
                staging.execute("delete from pending_turn_projections")
                staging.commit()
            db.execute("insert into chat_session_messages values('s','3','t2',3,'assistant','streaming',60,70,'local')")
            db.commit()
            self.assertEqual(session()["turn"],"inProgress")
            db.execute("update chat_session_messages set status='completed' where message_id='3'")
            db.commit()
            self.assertEqual(session()["turn"],"completed")
            self.assertNotIn("bufferedSince",session())


if __name__ == "__main__":
    unittest.main()
