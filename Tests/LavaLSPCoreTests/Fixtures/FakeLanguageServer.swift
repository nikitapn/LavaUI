// Compiled into the test bundle so it needs no SwiftPM resource declaration.
enum FakeLanguageServer {
    static let script = #"""
import json
import os
import sys

mode = sys.argv[1]
stdin = sys.stdin.buffer
stdout = sys.stdout.buffer
seen = []
waiting = set()
answers = {}
shutting_down = False

def read():
    headers = {}
    while (line := stdin.readline()) != b"\r\n":
        if not line:
            return None
        key, value = line.split(b":", 1)
        headers[key.lower()] = value.strip()
    return json.loads(stdin.read(int(headers[b"content-length"])))

def send(**fields):
    data = json.dumps(dict(jsonrpc="2.0", **fields)).encode()
    stdout.write(("Content-Length: %d\r\n\r\n" % len(data)).encode() + data)
    stdout.flush()

def reply(result):
    send(id=message["id"], result=result)

def notify(method, params):
    send(method=method, params=params)

while (message := read()) is not None:
    method = message.get("method")
    params = message.get("params")
    if method is None:
        answers[str(message["id"])] = message.get("result", message.get("error"))
        if len(answers) == 5:
            notify("fake/answers", answers)
    elif method == "initialize":
        assert params["rootUri"].startswith("file:///")
        assert params["initializationOptions"] == {"test": True}
        assert params["capabilities"]["general"]["positionEncodings"] == ["utf-8", "utf-16"]
        sync = {"openClose": True, "change": 2, "save": {"includeText": True}}
        if mode == "full":
            sync = 1
        caps = {"textDocumentSync": sync, "semanticTokensProvider": {
            "legend": {"tokenTypes": ["variable"], "tokenModifiers": ["readonly"]},
            "full": {"delta": True}}}
        if mode != "full":
            caps["positionEncoding"] = "utf-8"
        reply({"capabilities": caps})
    elif method == "initialized":
        sys.stderr.write("x" * 80000 + "\nready\n")
        sys.stderr.flush()
        send(id=10, method="workspace/configuration",
             params={"items": [{"section": "editor.option"}, {"section": "missing"}, {}]})
        send(id="register", method="client/registerCapability", params={"registrations": []})
        send(id=11, method="window/workDoneProgress/create", params={"token": "fake"})
        send(id="unknown", method="fake/unknown")
        send(id="unregister", method="client/unregisterCapability")
    elif method in ["textDocument/didOpen", "textDocument/didChange",
                    "textDocument/didSave", "textDocument/didClose"]:
        seen.append({"method": method, "params": params})
        if method == "textDocument/didOpen":
            doc = params["textDocument"]
            notify("textDocument/publishDiagnostics", {
                "uri": doc["uri"], "version": doc["version"], "diagnostics": [{
                    "range": {"start": {"line": 0, "character": 0},
                              "end": {"line": 0, "character": 1}},
                    "severity": 2, "message": "fixture warning", "source": "fake", "code": "W1"}]})
    elif method == "fake/seen":
        reply(seen)
    elif method == "fake/echo":
        reply(params)
    elif method == "fake/wait":
        waiting.add(message["id"])
    elif method == "$/cancelRequest":
        request_id = params["id"]
        assert request_id in waiting
        waiting.remove(request_id)
        send(id=request_id, error={"code": -32800, "message": "cancelled"})
        notify("fake/cancelled", None)
    elif method == "textDocument/semanticTokens/full":
        reply({"resultId": "full", "data": [0, 4, 1, 0, 1]})
    elif method == "textDocument/semanticTokens/full/delta":
        assert params["previousResultId"] == "full"
        reply({"resultId": "delta", "edits": [{"start": 1, "deleteCount": 1, "data": [6]}]})
    elif method == "fake/crash":
        os._exit(23)
    elif method == "fake/replyThenCrash":
        reply({"value": "last reply"})
        os._exit(23)
    elif method == "shutdown":
        if mode != "hang":
            shutting_down = True
            reply(None)
    elif method == "exit":
        sys.exit(0 if shutting_down else 1)
"""#
}
