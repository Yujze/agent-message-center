"""Read only session index metadata used by the local Windows HUD."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import time
from uuid import UUID


def open_index(path):
    return sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.25)


def columns(db, schema, table):
    return {r[1] for r in db.execute(f"PRAGMA {schema}.table_info({table})")}


def catalog_time(fields, name):
    options = [col for col in [name + "_ms"] if col in fields]
    if name in fields:
        options.append(f"{name} * 1000")
    return "COALESCE(" + ", ".join(options + ["NULL"]) + ")" if options else "NULL"


def codex_async_input_pending(db, tables, thread_id, turn_id):
    # The desktop projects each async prompt as an agent message. Only expose the
    # call ID, question count and matching reply IDs to the monitor.
    pending = {}
    for table in tables:
        questions = db.execute(f"""
            SELECT item_id, rollout_ordinal, json_array_length(item_json,'$.questions')
            FROM history.{table}
            WHERE thread_id=? AND turn_id=? AND item_type='agentMessage'
              AND json_valid(item_json) AND json_extract(item_json,'$.delivery')='async'
              AND json_type(item_json,'$.questions')='array'""", (thread_id, turn_id))
        for call, seq, count in questions:
            for index in range(count):
                key = (call, index)
                pending[key] = min(seq, pending.get(key, seq))
    if not pending:
        return False

    first = min(pending.values())
    begin, end = "<send_user_message_question_reply>", "</send_user_message_question_reply>"
    for table in tables:
        # Ordinary user text and answers never leave SQLite. Only parse the exact
        # desktop envelope, and only accept references to a question preceding it.
        replies = db.execute(f"""
            WITH parts AS (
                SELECT m.rollout_ordinal AS seq, trim(json_extract(c.value,'$.text'),
                        char(9)||char(10)||char(13)||' ') AS body
                FROM history.{table} m, json_each(m.item_json,'$.content') c
                WHERE m.thread_id=:thread AND m.turn_id=:turn AND m.rollout_ordinal>:first
                  AND m.item_type='userMessage' AND json_valid(m.item_json) AND c.type='object'
                  AND json_extract(c.value,'$.type')='text'
            ), envelopes AS (
                SELECT seq, substr(body,length(:begin)+1,length(body)-length(:begin)-length(:end)) AS payload
                FROM parts WHERE substr(body,1,length(:begin))=:begin AND substr(body,-length(:end))=:end
            )
            SELECT seq, json_extract(entry.value,'$.questionItemId') FROM envelopes,
                json_each(CASE WHEN json_valid(payload) THEN
                    CASE WHEN json_type(payload)='array' THEN payload END END) entry
            WHERE entry.type='object' AND json_type(entry.value,'$.answer') IS NOT NULL""", dict(thread=thread_id, turn=turn_id, first=first, begin=begin, end=end))
        for seq, ref in replies:
            if not isinstance(ref, str):
                continue
            try:
                key = json.loads(ref)
            except ValueError:
                continue
            if (isinstance(key, list) and len(key) == 3 and key[0] == "request_user_input_async"
                    and isinstance(key[1], str) and type(key[2]) is int):
                question = (key[1], key[2])
                if question in pending and pending[question] < seq:
                    del pending[question]
    return bool(pending)


def set_codex_side_chat_roots(sessions):
    by_id = {row["id"]: row for row in sessions}
    for row in sessions:
        if "parentId" not in row:
            continue
        seen = {row["id"]}
        parent = by_id.get(row["parentId"])
        while parent and "parentId" in parent and parent["id"] not in seen:
            seen.add(parent["id"])
            parent = by_id.get(parent["parentId"])
        row["rootId"] = parent["id"] if parent and parent["id"] not in seen else None


def session_snapshot(codex_home):
    with closing(open_index(codex_home / "state_5.sqlite")) as db:
        fields = columns(db, "main", "threads")
        parent = "attached_thread_parent_id" if "attached_thread_parent_id" in fields else "NULL"
        created = catalog_time(fields, "created_at")
        updated = catalog_time(fields, "updated_at")
        status = message = finished = unread = needs_input = "NULL"
        joins = ""
        if {"thread_id", "first_unread_turn"} <= columns(db, "main", "thread_read_receipts"):
            joins += " LEFT JOIN thread_read_receipts rr ON rr.thread_id=threads.id"
            unread = "CASE WHEN rr.thread_id IS NOT NULL THEN NULLIF(TRIM(rr.first_unread_turn),'') IS NOT NULL END"
        history_available = False
        turn_id = "NULL"
        async_tables = []
        try:
            history = (codex_home / "thread_history_1.sqlite").resolve().as_uri() + "?mode=ro"
            db.execute("ATTACH DATABASE ? AS history", (history,))
            turn_fields = columns(db, "history", "thread_turns")
            history_available = {"status", "thread_id", "rollout_ordinal"} <= turn_fields
            if history_available:
                joins += """ LEFT JOIN history.thread_turns last ON last.thread_id=threads.id AND
                    last.rollout_ordinal=(SELECT MAX(t.rollout_ordinal) FROM history.thread_turns t WHERE t.thread_id=threads.id)"""
                status = "last.status"
                if "turn_id" in turn_fields:
                    turn_id = "last.turn_id"
                if "completed_at" in turn_fields:
                    finished = "CASE WHEN last.status='completed' THEN last.completed_at*1000 END"
            parts, requests = [], []
            for table in ("thread_items", "thread_realtime_items"):
                keys = columns(db, "history", table)
                if turn_id != "NULL" and {"thread_id","turn_id","item_id","item_type","item_json","rollout_ordinal"} <= keys:
                    async_tables.append(table)
                if history_available and "turn_id" in turn_fields and {
                    "thread_id","turn_id","item_id","item_type","item_json","updated_at_ordinal","rollout_ordinal"
                } <= keys:
                    requests.append(f"""SELECT item_id, COALESCE(updated_at_ordinal,rollout_ordinal) AS seq,
                        json_extract(item_json,'$.status') AS status FROM history.{table}
                        WHERE thread_id=threads.id AND turn_id=last.turn_id AND item_type='dynamicToolCall'
                        AND json_valid(item_json) AND json_extract(item_json,'$.tool')='request_user_input'""")
                if not {"created_at_ms", "item_type", "rollout_ordinal", "thread_id"} <= keys:
                    continue
                stamp = "COALESCE(completed_at_ms, created_at_ms)" if "completed_at_ms" in keys else "created_at_ms"
                parts.append(f"""(SELECT {stamp} FROM history.{table} WHERE thread_id=threads.id
                                  AND item_type IN ('userMessage','agentMessage') AND {stamp} > 0
                                  ORDER BY rollout_ordinal DESC LIMIT 1)""")
            if parts:
                message = "MAX(" + ", ".join("COALESCE(" + p + ",0)" for p in parts) + ",0)"
            if requests:
                # Only a synchronous, still-open question in the current turn is evidence.
                calls = " UNION ALL ".join(requests)
                needs_input = f"""CASE WHEN last.status='inProgress' AND EXISTS (
                    SELECT 1 FROM (SELECT status, ROW_NUMBER() OVER (
                        PARTITION BY item_id ORDER BY seq DESC, (status IN ('completed','failed')) DESC
                    ) AS position FROM ({calls})) WHERE position=1 AND status='inProgress') THEN 1 END"""
        except sqlite3.OperationalError:
            pass
        db.execute("BEGIN")
        rows = db.execute(f"""SELECT threads.id, {created}, {updated}, threads.name, {status}, {message},
                              {finished}, {unread}, {needs_input}, {turn_id}, {parent} FROM threads {joins} WHERE archived=0 AND source='vscode'
                              ORDER BY updated_at DESC, id DESC""").fetchall()
        sessions = []
        for ident, created_ms, updated_ms, name, turn, msg, finished_ms, unread_flag, waiting, active_turn, parent_id in rows:
            try:
                parsed = UUID(ident)
                if str(parsed) != ident or not parsed.int:
                    continue
            except (TypeError, ValueError, AttributeError):
                continue
            turn = turn if turn in {"inProgress", "completed", "interrupted", "failed"} else "unknown"
            if turn == "inProgress" and active_turn and not waiting and codex_async_input_pending(db, async_tables, ident, active_turn):
                waiting = 1
            sessions.append(dict(agent="Codex", id=ident, name=" ".join((name or "")[:80].split()), turn=turn,
                                 created=created_ms, message=msg or None, activity=max(msg or 0, created_ms or 0, finished_ms or 0),
                                 finished=finished_ms, unread=unread_flag, needsInput=waiting,
                                 updated=(updated_ms or 0) // 1000))
            if name and name != sessions[-1]["name"]:
                sessions[-1]["desktopTitle"] = name
            if parent_id is not None:
                sessions[-1]["parentId"] = parent_id
    set_codex_side_chat_roots(sessions)
    summary = dict(total=len(sessions), running=sum(s["turn"] == "inProgress" for s in sessions),
                   completed=sum(s["turn"] == "completed" for s in sessions))
    if sessions and not history_available:
        summary.update(running=None, completed=None)
    return {"sessions": sessions, "summary": summary}


def qoder_sessions(path):
    # Desktop IDE catalog. Only select timestamps for user and assistant messages.
    with closing(open_index(path)) as db:
        rows = db.execute("""
            SELECT s.session_id, substr(s.session_title,1,80), s.gmt_create, s.last_user_query_at,
                   (SELECT MAX(m.gmt_create) FROM chat_message m WHERE m.session_id=s.session_id
                    AND m.role IN ('user','assistant'))
            FROM chat_session s WHERE s.session_type IN ('assistant','quest')
              AND COALESCE(s.parent_session_id,'')='' ORDER BY s.session_id
        """).fetchall()
    result = []
    for ident, title, created, prompt, reply in rows:
        if not ident:
            continue
        msg = max(reply or 0, prompt or 0)
        result.append(dict(agent="Qoder", id=ident, name=title or "", created=created,
                           message=msg or None, activity=max(created or 0, msg), turn="unknown"))
    return result


def qoder_app_sessions(path):
    with closing(open_index(path)) as db:
        # Older messages without projected role metadata still contribute through
        # the sidebar update time. Never unpack message payloads to infer a role.
        fields = columns(db, "main", "chat_session_messages")
        session_fields = columns(db, "main", "chat_sessions")
        unread = "s.unread" if "unread" in session_fields else "NULL"
        message = turn_status = turn_time = "NULL"
        latest_join = ""
        if {"session_id", "role", "created_at"} <= fields:
            stamp = "COALESCE(m.created_at,0)"
            if "updated_at" in fields:
                stamp = f"MAX({stamp},COALESCE(m.updated_at,0))"
            visible = "AND COALESCE(m.has_visible_content,1) = 1" if "has_visible_content" in fields else ""
            message = f"""(SELECT MAX({stamp}) FROM chat_session_messages m
                           WHERE m.session_id = s.session_id AND m.role IN ('user','assistant') {visible})"""
        if {"message_id","sequence","session_id","turn_id","status","role","created_at"} <= fields:
            def role(alias):
                if "payload_json" in fields:
                    return (f"COALESCE({alias}.role, CASE WHEN json_valid({alias}.payload_json) THEN "
                            f"json_extract({alias}.payload_json,'$.role') END)")
                return f"{alias}.role"
            # Use the same latest user/assistant turn and assistant status as the desktop sidebar.
            local = " AND m.source != 'peer-projection'" if "source" in fields else ""
            latest_join = f""" LEFT JOIN chat_session_messages last ON last.session_id=s.session_id
                AND last.message_id=(SELECT m.message_id FROM chat_session_messages m
                  WHERE m.session_id=s.session_id {local} AND {role('m')}='assistant'
                    AND m.turn_id=(SELECT m.turn_id FROM chat_session_messages m WHERE m.session_id=s.session_id
                      {local} AND NULLIF(TRIM(m.turn_id),'') IS NOT NULL AND {role('m')} IN ('user','assistant')
                      ORDER BY m.sequence DESC LIMIT 1)
                  ORDER BY m.sequence DESC LIMIT 1)"""
            turn_status = "last.status"
            turn_time = "COALESCE(NULLIF(last.updated_at,0),last.created_at)" if "updated_at" in fields else "last.created_at"
        rows = db.execute(f"""
            SELECT s.session_id, s.title, s.created_at, s.updated_at, {message}, {turn_status}, {turn_time}, {unread}
            FROM chat_sessions s {latest_join} WHERE s.session_kind='standard' AND COALESCE(s.archived,0)=0
              AND COALESCE(s.deleted_at,0)=0 AND COALESCE(s.archived_at,0)=0
            ORDER BY s.session_id
        """).fetchall()
    return [dict(agent="Qoder", id=ident, name=(title or "")[:80], desktop=True, created=created,
                 message=msg or None, activity=max(created or 0, updated or 0, msg or 0),
                 turn={"completed":"completed","interrupted":"interrupted","failed":"failed","streaming":"inProgress"}.get(status,"unknown"),
                 finished=stamp if status == "completed" else None, unread=flag)
            for ident, title, created, updated, msg, status, stamp, flag in rows if ident]


def qoder_catalog(roaming):
    sessions = {}
    ready = failed = False
    for path, reader in ((roaming / "com.qoder.app.stable/main.sqlite", qoder_app_sessions),
                         (roaming / "Qoder/SharedClientCache/cache/db/local.db", qoder_sessions)):
        try:
            if not path.is_file():
                continue
            batch = reader(path)
        except (sqlite3.Error, OSError, TypeError, ValueError):
            failed = True
            continue
        ready = True
        for row in batch:
            previous = sessions.get(row["id"])
            if previous is None:
                sessions[row["id"]] = row
                continue
            if row["name"] and (not previous["name"] or row["activity"] > previous["activity"]):
                previous["name"] = row["name"]
            if (row["message"] or 0) > previous["activity"]:
                # An IDE message can advance a shared conversation beyond the desktop receipt.
                previous.update(turn="unknown", unread=None, finished=None)
            times = [t for t in (previous["created"], row["created"]) if t]
            previous["created"] = min(times, default=None)
            previous["activity"] = max(previous["activity"], row["activity"])
            previous["message"] = max(previous["message"] or 0, row["message"] or 0) or None
    if failed:
        status = "partial" if ready else "unavailable"
    else:
        status = "ready" if ready else "missing"
    return list(sessions.values()), status


def dsh_projection(db, path, now):
    stamp = path.stat()
    if not 0 < stamp.st_size <= 4 * 1024 * 1024:
        raise ValueError("Invalid projection size")
    fields = db.execute("""
        WITH projection(j) AS (SELECT CAST(? AS TEXT)),
             data AS (SELECT j, json_extract(j,'$.record.rows.turnBoundary.val') AS boundary FROM projection)
        SELECT json_extract(j,'$.record.identity.createdAt'),
               json_extract(j,'$.record.rows.title.val'),
               json_extract(j,'$.record.rows.sessionListMetadata.val.lastPromptAt'),
               json_extract(j,'$.record.rows.timeContext.val.lastMessageTime'),
               json_extract(j,'$.record.rows.sessionListMetadata.val.blank'),
               json_extract(j,'$.record.rows.subagent.val.identity.mode'),
               json_type(boundary,'$.openTurnStartSeq'), json_extract(boundary,'$.lastTurn'),
               EXISTS(SELECT 1 FROM json_each(j,'$.record.rows.userQuestions.val.questions.active') q
                      WHERE CASE WHEN q.type='object' THEN json_extract(q.value,'$.state') IS NOT 'continued' END)
        FROM data WHERE json_type(j,'$.record.rows')='object'""", (path.read_bytes(),)).fetchone()
    if fields is None:
        raise ValueError("Incomplete projection")
    created, title, prompt, last_message, blank, child, open_type, last_turn, question = fields
    if blank or child:
        return None
    if any(x is not None and type(x) is not int for x in (created, prompt, last_message, last_turn)):
        raise ValueError("Invalid projection metadata")
    if title is not None and not isinstance(title, str):
        raise ValueError("Invalid session title")
    message = max(last_message or 0, prompt or 0)
    waiting = open_type == "integer" and bool(question)
    if open_type == "integer":
        # A stale open checkpoint can survive an app exit. A pending question
        # persists until answered, even after the normal activity window.
        heartbeat = max(message, min(stamp.st_mtime_ns // 1_000_000, now))
        turn = "inProgress" if waiting or now - heartbeat <= 600_000 else "unknown"
    elif open_type in ("null", None) and (last_turn or 0) > 0:
        turn = "completed"
    else:
        turn = "idle" if open_type == "null" else "unknown"
    return dict(agent="DSH", id=path.stem, name=(title or "")[:80], desktopTitle=title or "",
                turn=turn, needsInput=int(waiting), created=created, message=message or None,
                activity=max(message, created or 0), finished=last_message if turn == "completed" else None)


def dsh_id(stem):
    # Desktop workspaces can store the bare UUID or the session-prefixed key.
    if stem.startswith("session-"):
        suffix = stem[8:]
        try:
            if str(UUID(suffix)) == suffix:
                return suffix
        except ValueError:
            pass
    return stem


def dsh_catalog(index):
    directory = index.parent / "session_projcache" / "sessions"
    try:
        has_index = index.is_file()
        if not has_index and not directory.is_dir():
            return [], "missing"
        with closing(sqlite3.connect(":memory:")) as db:
            members, archived = set(), set()
            if has_index:
                workspace = index.read_bytes()
                members.update(dsh_id(sid) for sid, in db.execute("""
                    SELECT s.value FROM json_each(?,'$.tables.workspaces') w,
                    json_each(w.value,'$.sessionIds') s WHERE s.type='text'""", (workspace,)))
                archived.update(dsh_id(sid) for sid, in db.execute("""
                    SELECT value FROM json_each(?,'$.global.archivedSessionIds') WHERE type='text'""", (workspace,)))
            if not directory.is_dir():
                return [], "unavailable" if members - archived else "ready"
            missing = members - archived
            partial = not has_index
            sessions = {}
            now = time.time_ns() // 1_000_000
            for path in sorted(directory.iterdir()):
                ident = dsh_id(path.stem)
                if path.suffix.lower() != ".json" or ident in archived:
                    continue
                try:
                    row = dsh_projection(db, path, now)
                    missing.discard(ident)
                    if row is not None and (ident not in sessions or row["activity"] >= sessions[ident]["activity"]):
                        sessions[ident] = row
                except (OSError, sqlite3.Error, TypeError, ValueError):
                    # Writers may be between checkpoints. Retry this file next poll.
                    partial = True
        return list(sessions.values()), "partial" if partial or missing else "ready"
    except (OSError, sqlite3.Error):
        return [], "unavailable"


def desktop_snapshot(codex_home, dsh_home, roaming):
    rows, sources = [], {}
    running = completed = 0
    counts_known = False
    try:
        if (codex_home / "state_5.sqlite").exists():
            snapshot = session_snapshot(codex_home)
            rows.extend(snapshot["sessions"])
            running = snapshot["summary"]["running"]
            completed = snapshot["summary"]["completed"]
            counts_known = running is not None
            sources["Codex"] = "ready"
        else:
            sources["Codex"] = "missing"
    except (OSError, sqlite3.Error, ValueError, TypeError):
        sources["Codex"] = "unavailable"
    dsh, sources["DSH"] = dsh_catalog(dsh_home / "storages/workspace.json")
    rows.extend(dsh)
    qoder, sources["Qoder"] = qoder_catalog(roaming)
    rows.extend(qoder)
    uncertain = (any(row["agent"] != "Codex" for row in rows)
                 or any(value in {"partial", "unavailable"} for value in sources.values()))
    return {"sessions": rows, "sources": sources, "summary": dict(total=len(rows), running=running,
            completed=completed, partial=uncertain, countsKnown=counts_known and sources["Codex"] == "ready")}


if __name__ == "__main__":
    home = Path.home()
    codex = Path(os.environ.get("CODEX_HOME") or home / ".codex")
    if "--fixture" in sys.argv:
        base = Path(os.environ["CODEX_HOME"])
        result = desktop_snapshot(base, base / "dsh", base / "roaming")
    else:
        result = desktop_snapshot(codex, Path(os.environ.get("DSH_HOME") or home / ".dsh"),
                                  Path(os.environ.get("APPDATA") or home / "AppData/Roaming"))
    print(json.dumps(result))
