"""Room status derived from the runtime, and reconciliation after failures."""

import uuid


def rid() -> str:
    return uuid.uuid4().hex


def new_room(client, join=False) -> dict:
    room = client.post("/v1/rooms", json={"nickname": "Ana", "half_length_s": 30, "request_id": rid()}).json()
    if join:
        client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Bia", "request_id": rid()})
    return room


def status(client, code) -> str:
    return client.get(f"/v1/rooms/{code}").json()["status"]


def stored_status(client, code) -> str:
    with client.service.pool.connection() as conn:
        return conn.execute("SELECT status FROM rooms WHERE room_code = %s", (code,)).fetchone()["status"]


def test_status_follows_the_runtime(client, fake_runtime):
    room = new_room(client, join=True)
    code, match_id = room["room_code"], room["match_id"]
    fake_runtime.set_state(match_id, "running")
    assert status(client, code) == "running"
    fake_runtime.set_state(match_id, "paused")
    assert status(client, code) == "paused"
    fake_runtime.set_state(match_id, "completed")
    assert status(client, code) == "completed" and stored_status(client, code) == "completed"
    assert client.get("/v1/rooms/NOROOM").status_code == 404


def test_unreachable_runtime_reports_unavailable_without_storing_it(client, fake_runtime):
    room = new_room(client)
    fake_runtime.down = True
    assert status(client, room["room_code"]) == "unavailable"
    assert stored_status(client, room["room_code"]) == "waiting"
    fake_runtime.down = False
    assert status(client, room["room_code"]) == "waiting"


def test_runtime_restart_aborts_a_running_match(client, fake_runtime):
    room = new_room(client, join=True)
    fake_runtime.set_state(room["match_id"], "running")
    assert status(client, room["room_code"]) == "running"
    fake_runtime.restart()   # new boot_id, live matches gone (404)
    assert status(client, room["room_code"]) == "aborted"
    assert stored_status(client, room["room_code"]) == "aborted"


def test_new_boot_id_for_a_live_match_aborts_it(client, fake_runtime):
    room = new_room(client, join=True)
    fake_runtime.set_state(room["match_id"], "running")
    fake_runtime.boot_id = str(uuid.uuid4())   # same match, different process: can't be ours
    assert status(client, room["room_code"]) == "aborted"


def test_terminal_rooms_reject_joins(client, fake_runtime):
    room = new_room(client)
    fake_runtime.set_state(room["match_id"], "cancelled")
    assert status(client, room["room_code"]) == "cancelled"
    r = client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Bia", "request_id": rid()})
    assert r.status_code == 409 and r.json()["error"] == "room_closed"


def test_pending_join_is_confirmed_by_a_retry(client, fake_runtime):
    room = new_room(client)
    request_id = rid()
    fake_runtime.down = True
    r = client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Bia", "request_id": request_id})
    assert r.status_code == 503
    fake_runtime.down = False
    assert client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Cy", "request_id": rid()}).status_code == 409
    retry = client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Bia", "request_id": request_id})
    assert retry.status_code == 200 and retry.json()["team"] == 1


def test_reconcile_releases_a_stale_pending_join(client, fake_runtime):
    room = new_room(client)
    fake_runtime.down = True
    client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Bia", "request_id": rid()})
    fake_runtime.down = False
    with client.service.pool.connection() as conn:
        conn.execute("UPDATE reservations SET created_at = now() - interval '10 minutes' WHERE team = 1")
    assert client.service.reconcile_all() == 1
    r = client.post(f"/v1/rooms/{room['room_code']}/join", json={"nickname": "Cy", "request_id": rid()})
    assert r.status_code == 200 and r.json()["nickname"] == "Cy"


def test_reconcile_confirms_a_pending_join_the_runtime_holds(client, fake_runtime):
    room = new_room(client)
    code = room["room_code"]
    with client.service.pool.connection() as conn:
        row = conn.execute("SELECT player_id FROM reservations WHERE room_code = %s", (code,)).fetchone()
        res_id = uuid.uuid4()
        conn.execute("INSERT INTO reservations (reservation_id, room_code, team, player_id, nickname, request_id) "
                     "VALUES (%s, %s, 1, %s, 'Bia', %s)", (res_id, code, row["player_id"], rid()))
    fake_runtime.matches[room["match_id"]]["res"][1] = {"reservation_id": str(res_id), "player_id": "x", "nickname": "Bia"}
    client.service.reconcile_all()
    assert [p["nickname"] for p in client.get(f"/v1/rooms/{code}").json()["players"]] == ["Ana", "Bia"]


def test_reconcile_cleans_up_a_room_stuck_in_provisioning(client, fake_runtime):
    room = new_room(client)
    with client.service.pool.connection() as conn:
        conn.execute("UPDATE rooms SET status = 'provisioning', created_at = now() - interval '10 minutes'")
    client.service.reconcile_all()
    assert client.get(f"/v1/rooms/{room['room_code']}").status_code == 404
    assert fake_runtime.terminal.get(room["match_id"]) == "cancelled"


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}
