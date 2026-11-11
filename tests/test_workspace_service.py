"""Protocol and completion regressions, using an in-memory window backend."""
import copy
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from workspace_service import LocalServer, PersistentNativeBackend, RequestHandler, WorkspaceService
from workspacectl import exchange


class FakeBackend:
    def __init__(self):
        self.calls = []
        self.delay = 0
        self.wrong_rectangle = False
        self.state = {
            "ok": True,
            "context": {"activeSpaces": [10], "frontPID": 9, "frontApp": "com.example.user"},
            "spaces": [
                {"index": index, "id": sid, "type": 0, "count": 3 if sid == 12 else 0,
                 "frame": {"x": 0, "y": 25, "width": 1280, "height": 775}}
                for index, sid in enumerate([10, 11, 12, 13], 1)
            ],
            "windows": [
                {"id": wid, "pid": 30, "app": "com.example.task", "app_name": "Task App", "owner_name": "Task Owner", "spaces": [12],
                 "bounds": {"X": 50, "Y": y, "Width": 500, "Height": 400}}
                for wid, y in [(101, 50), (102, 100), (103, 150)]
            ],
        }

    def __call__(self, request):
        self.calls.append(copy.deepcopy(request))
        if request["command"] == "snapshot":
            return copy.deepcopy(self.state)
        if request["command"] == "bind_process":
            return {"ok": True, "binding_state": "submitted"}
        if request["command"] != "apply":
            raise ValueError("Unsupported fake request")
        time.sleep(self.delay)
        results = []
        for change in request["windows"]:
            window = next(w for w in self.state["windows"] if w["id"] == change["id"])
            window["spaces"] = [change["toSpace"]]
            if "frame" in change:
                frame = change["frame"]
                window["bounds"] = {native: frame[key] for key, native in
                                    [("x", "X"), ("y", "Y"), ("width", "Width"), ("height", "Height")]}
            actual = {key: copy.deepcopy(window[key]) for key in ["id", "spaces", "bounds"]}
            if self.wrong_rectangle:
                actual["bounds"]["X"] += 100
            results.append(actual)
        for space in self.state["spaces"]:
            space["count"] = sum(space["id"] in w["spaces"] for w in self.state["windows"])
        context = self.state["context"]
        return {"ok": True, "results": results, "context": context, "afterContext": context}


class WorkspaceServiceTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.service = WorkspaceService(self.backend)
        self.service.refresh()

    def request(self, method, **params):
        return self.service.dispatch({"id": "test-request", "method": method, "params": params})

    def test_cached_state_does_not_call_the_backend(self):
        initial_calls = len(self.backend.calls)
        result = self.request("state", windows=[102])
        self.assertEqual([w["id"] for w in result["windows"]], [102])
        self.assertEqual(len(self.backend.calls), initial_calls)
        self.assertGreaterEqual(result["cache_age_ms"], 0)

    def test_state_refreshes_old_metadata_without_requiring_a_flag(self):
        self.service.observed_ns -= 300_000_000
        self.backend.state["windows"][0]["spaces"] = [13]
        initial_calls = len(self.backend.calls)
        result = self.request("state", windows=[101])
        self.assertEqual(result["windows"][0]["spaces"], [13])
        self.assertEqual(len(self.backend.calls), initial_calls + 1)
        self.assertLess(result["cache_age_ms"], 250)

    def test_arrange_verifies_bounds_and_preserves_explicit_order(self):
        result = self.request("arrange", workspace=3, windows=[103, 101, 102],
                              layout="main-left", ratio=.55, gap=4)
        self.assertTrue(result["ok"])
        self.assertTrue(result["context_unchanged"])
        self.assertEqual(result["completion_scope"], "verified_window_geometry")
        self.assertEqual([w["id"] for w in result["results"]], [103, 101, 102])
        bounds = [w["bounds"] for w in result["results"]]
        self.assertEqual(bounds[1]["X"] - bounds[0]["X"] - bounds[0]["Width"], 4)

    def test_explicit_action_reuses_cache_and_updates_only_verified_rows(self):
        observed = self.service.observed_ns
        initial_calls = len(self.backend.calls)
        result = self.request("move", workspace=2, windows=[101])
        self.assertTrue(result["ok"])
        self.assertEqual([call["command"] for call in self.backend.calls[initial_calls:]], ["apply"])
        cached = self.request("state", windows=[101])
        self.assertEqual(cached["windows"][0]["spaces"], [11])
        self.assertEqual(self.service.observed_ns, observed)

    def test_position_selection_and_vacancy_require_fresh_metadata(self):
        for extra in ({"main": "rightmost"}, {"require_empty": True}):
            initial_calls = len(self.backend.calls)
            self.request("arrange", workspace=3, windows=[101, 102, 103], **extra)
            self.assertEqual(self.backend.calls[initial_calls]["command"], "snapshot")

    def test_human_name_and_keep_locate_the_original_workspace_without_ids(self):
        result = self.request("arrange", workspace="keep", apps=["tAsK ApP"], layout="main-right")
        self.assertTrue(result["ok"])
        applied = next(call for call in self.backend.calls if call["command"]=="apply")
        self.assertEqual(len(applied["windows"]), 3)
        self.assertTrue(all(w["fromSpace"]==12 and w["toSpace"]==12 for w in applied["windows"]))
        self.assertTrue(all(w["spaces"]==[12] for w in result["results"]))

    def test_exact_owner_name_bundle_tail_and_bundle_id_are_case_insensitive(self):
        for name in ("TASK OWNER", "Task", "COM.EXAMPLE.TASK"):
            result = self.request("state", apps=[name])
            self.assertTrue(result["ok"])
            self.assertEqual(len(result["windows"]), 3)

    def test_partial_app_names_do_not_guess(self):
        result = self.request("arrange", workspace="keep", apps=["Task A"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "application_not_found")
        self.assertFalse(any(call["command"]=="apply" for call in self.backend.calls))

    def test_same_human_name_reports_bundle_candidates_without_mutation(self):
        extra = copy.deepcopy(self.backend.state["windows"][0])
        extra.update(id=200, pid=40, app="org.other.task", app_name="Task App")
        self.backend.state["windows"].append(extra)
        result = self.request("arrange", workspace="keep", apps=["task app"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "ambiguous_application")
        self.assertEqual({a["app"] for a in result["applications"]}, {"com.example.task", "org.other.task"})
        self.assertFalse(any(call["command"]=="apply" for call in self.backend.calls))

    def test_exact_bundle_id_disambiguates_a_colliding_human_name(self):
        extra = copy.deepcopy(self.backend.state["windows"][0])
        extra.update(id=200, pid=40, app="org.other.editor", app_name="com.example.task")
        self.backend.state["windows"].append(extra)
        result = self.request("arrange", workspace="keep", apps=["com.example.task"])
        self.assertTrue(result["ok"])
        self.assertEqual({w["id"] for w in result["results"]}, {101,102,103})

    def test_protected_application_name_is_rejected_before_any_mutation(self):
        window=self.backend.state["windows"][0]
        window.update(app="com.tencent.xinWeChat", app_name="WeChat", owner_name="WeChat")
        result=self.request("arrange", workspace="keep", apps=["wechat"])
        self.assertFalse(result["ok"])
        self.assertIn("protected", result["error"])
        self.assertFalse(any(call["command"]=="apply" for call in self.backend.calls))

    def test_keep_cross_workspace_ambiguity_returns_precise_candidates(self):
        self.backend.state["windows"][1]["spaces"] = [11]
        result = self.request("arrange", workspace="keep", apps=["Task App"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "ambiguous_workspace")
        self.assertEqual(result["workspaces"], [{"index":2,"id":11,"type":0}, {"index":3,"id":12,"type":0}])
        self.assertFalse(any(call["command"]=="apply" for call in self.backend.calls))

    def test_keep_explicit_ids_can_disambiguate_application_workspaces(self):
        self.backend.state["windows"][1]["spaces"] = [11]
        self.service.refresh()
        result = self.request("arrange", workspace="keep", apps=["Task App"], windows=[101], layout="fill")
        self.assertTrue(result["ok"])
        self.assertEqual(result["results"][0]["spaces"], [12])

    def test_keep_source_workspace_can_disambiguate_without_ids(self):
        self.backend.state["windows"][1]["spaces"] = [11]
        result = self.request("arrange", workspace="keep", apps=["Task App"], from_workspace=2, layout="fill")
        self.assertTrue(result["ok"])
        self.assertEqual(result["results"][0]["id"], 102)
        self.assertEqual(result["results"][0]["spaces"], [11])

    def test_keep_rejects_nonordinary_spaces(self):
        self.backend.state["spaces"][2]["type"] = 4
        result = self.request("arrange", workspace="keep", apps=["Task App"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "ordinary_workspace_required")
        self.assertEqual(result["workspaces"], [{"index":3,"id":12,"type":4}])

    def test_success_flag_without_actual_geometry_is_rejected(self):
        self.backend.wrong_rectangle = True
        result = self.request("arrange", workspace=3, windows=[101, 102, 103])
        self.assertFalse(result["ok"])
        self.assertIn("verify every requested rectangle", result["error"])
        self.assertFalse(result["deadline_met"])

    def test_late_completion_is_reported_as_missing_the_deadline(self):
        self.backend.delay = 1.01
        result = self.request("move", workspace=2, windows=[101])
        self.assertTrue(result["ok"])
        self.assertFalse(result["deadline_met"])
        self.assertGreater(result["request_elapsed_ms"], 1000)

    def test_reservations_skip_active_and_other_tasks_workspaces(self):
        first = self.request("reserve", workspace="auto", task="first")
        second = self.request("reserve", workspace="auto", task="second")
        self.assertEqual(first["workspace"]["id"], 11)
        self.assertEqual(second["workspace"]["id"], 13)
        self.assertFalse(first["ready_for_window_creation"])

    def test_binding_submission_is_not_creation_readiness(self):
        result = self.request("prepare", workspace=2, task="test", pid=30, apps=["com.example.task"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["binding_state"], "submitted")
        self.assertFalse(result["ready_for_window_creation"])

    def test_uncontrolled_creation_requires_an_adapter(self):
        calls = len(self.backend.calls)
        result = self.request("open", app="com.example.task")
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "route_required")
        self.assertEqual(len(self.backend.calls), calls)

    def test_application_scope_excludes_panels_from_tiling(self):
        self.backend.state["windows"].append({"id": 200, "pid": 30, "app": "com.example.task",
            "spaces": [12], "window_type": "panel_or_system",
            "bounds": {"X": 0, "Y": 0, "Width": 1280, "Height": 25}})
        result = self.request("arrange", workspace=3, apps=["com.example.task"])
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["results"]), 3)

    def test_protected_app_is_rejected_before_any_mutation(self):
        self.backend.state["windows"][0]["app"] = "com.tencent.xinWeChat"
        self.service.refresh()
        result = self.request("move", workspace=2, windows=[101])
        self.assertFalse(result["ok"])
        self.assertIn("protected", result["error"])
        self.assertFalse(any(call["command"] == "apply" for call in self.backend.calls))

    def test_socket_survives_invalid_json_and_echoes_request_id(self):
        with tempfile.TemporaryDirectory(prefix="wl-", dir="/tmp") as directory:
            path = Path(directory) / "api.sock"
            server = LocalServer(str(path), RequestHandler)
            server.service = self.service
            os.chmod(path, 0o600)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                    connection.connect(str(path))
                    connection.sendall(b"invalid-json\n")
                    response = json.loads(connection.makefile("rb").readline())
                self.assertFalse(response["ok"])
                response = exchange(path, {"id": "next-request", "method": "status"})
                self.assertEqual(response["id"], "next-request")
                self.assertTrue(response["ready"])
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


class PersistentNativeBackendTests(unittest.TestCase):
    def test_unresponsive_helper_is_bounded_and_not_replayed(self):
        command = [sys.executable, "-c", "import sys,time;sys.stdin.readline();time.sleep(5)"]
        backend = PersistentNativeBackend(command, timeout=.02)
        began = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "completion is unknown.*not replayed"):
            backend({"command": "apply"})
        self.assertLess(time.monotonic()-began, 3)
        self.assertIsNone(backend.process)

    def test_reuses_owned_helper_and_does_not_replay_a_disconnected_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory)/"helper.py"
            log = Path(directory)/"calls.jsonl"
            script.write_text('''import json,os,sys
for line in sys.stdin:
    request=json.loads(line)
    with open(sys.argv[1],"a") as log: log.write(json.dumps(request)+"\\n")
    if request["command"]=="apply": os._exit(7)
    print(json.dumps({"ok":request["command"]!="invalid","pid":os.getpid(),
                      "helper_usage":{"pid":os.getpid(),"cpu_seconds":.01,"max_rss_bytes":1234}}),flush=True)
''')
            backend = PersistentNativeBackend([sys.executable, str(script), str(log)])
            try:
                first = backend({"command": "snapshot"})
                with self.assertRaises(RuntimeError): backend({"command": "invalid"})
                second = backend({"command": "snapshot"})
                self.assertEqual(first["pid"], second["pid"])
                self.assertEqual(backend.usage()["cpu_seconds"], .01)
                with self.assertRaisesRegex(RuntimeError, "not replayed"):
                    backend({"command": "apply"})
                third = backend({"command": "snapshot"})
                self.assertNotEqual(first["pid"], third["pid"])
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(sum(call["command"]=="apply" for call in calls), 1)
            finally:
                process = backend.process
                backend.close()
                self.assertIsNotNone(process.returncode)


if __name__ == "__main__":
    unittest.main()
