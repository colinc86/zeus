#!/usr/bin/env python3
"""Deterministic localhost model for private-CLI prompt-answer tests; no credentials."""
import http.server
import json
import re
import threading
import time
import uuid

seen = set()
lock = threading.Lock()


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.path.endswith("count_tokens"):
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(b'{"input_tokens":1}'); return
        anthropic = self.path.split("?")[0].endswith("/messages")
        chat = self.path.split("?")[0].endswith("/chat/completions")
        history = json.dumps(body.get("messages" if anthropic or chat else "input", []))
        matches = re.findall(r"P1_PERMISSION_[a-z]+_[A-F0-9-]{36}", history)
        names = [entry.get("function", entry).get("name") for entry in body.get("tools", [])]
        candidate = "Bash" if anthropic else "exec_command" if "exec_command" in names else "bash"
        tool = None
        if matches and candidate in names:
            with lock:
                if matches[-1] not in seen:
                    seen.add(matches[-1]); tool = candidate
        command = "printf P1_PROCEEDED > p1-approval.txt"
        arguments = {"command": command, "description": "Write the private permission fixture"} if candidate != "exec_command" else {
            "cmd": command, "sandbox_permissions": "require_escalated", "justification": "Write the private permission fixture"}
        print(json.dumps({"path": self.path, "trigger": matches[-1] if matches else None, "tool": tool, "tools": names}), flush=True)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def event(value, name=None):
            prefix = "event: " + name + "\n" if name else ""
            self.wfile.write((prefix + "data: " + json.dumps(value) + "\n\n").encode()); self.wfile.flush()
        try:
            if anthropic:
                event({"type": "message_start", "message": {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
                    "model": body.get("model", "fixture"), "content": [], "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 1}}}, "message_start")
                content = {"type": "tool_use", "id": "tool_" + uuid.uuid4().hex, "name": tool, "input": {}} if tool else {"type": "text", "text": ""}
                event({"type": "content_block_start", "index": 0, "content_block": content}, "content_block_start")
                delta = {"type": "input_json_delta", "partial_json": json.dumps(arguments)} if tool else {"type": "text_delta", "text": "P1_READY"}
                event({"type": "content_block_delta", "index": 0, "delta": delta}, "content_block_delta")
                event({"type": "content_block_stop", "index": 0}, "content_block_stop")
                event({"type": "message_delta", "delta": {"stop_reason": "tool_use" if tool else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}, "message_delta")
                event({"type": "message_stop"}, "message_stop")
            elif chat:
                delta = {"tool_calls": [{"index": 0, "id": "call_" + uuid.uuid4().hex, "type": "function", "function": {"name": tool, "arguments": json.dumps(arguments)}}]} if tool else {"role": "assistant", "content": "P1_READY"}
                chunk = {"id": "chat_fixture", "object": "chat.completion.chunk", "created": int(time.time()), "model": body.get("model", "fixture"),
                         "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
                event(chunk); chunk["choices"][0] = {"index": 0, "delta": {}, "finish_reason": "tool_calls" if tool else "stop"}; event(chunk)
                self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
            else:
                item = {"id": "fc_" + uuid.uuid4().hex, "type": "function_call", "name": tool, "call_id": "call_" + uuid.uuid4().hex,
                        "arguments": json.dumps(arguments), "status": "completed"} if tool else {
                    "id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "P1_READY", "annotations": []}]}
                response = {"id": "resp_" + uuid.uuid4().hex, "object": "response", "created_at": int(time.time()), "status": "completed", "model": "fixture",
                            "output": [item], "error": None, "incomplete_details": None, "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
                event({"type": "response.created", "response": dict(response, status="in_progress", output=[])})
                event({"type": "response.output_item.added", "output_index": 0, "item": dict(item, status="in_progress")})
                if not tool:
                    event({"type": "response.content_part.added", "item_id": item["id"], "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}})
                    event({"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0, "content_index": 0, "delta": "P1_READY"})
                event({"type": "response.output_item.done", "output_index": 0, "item": item})
                event({"type": "response.completed", "response": response})
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    print("http://127.0.0.1:" + str(server.server_port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
