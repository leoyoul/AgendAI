#!/usr/bin/env python3
"""Test-only echo sidecar for PersistentJSONLSidecarTransport tests.

Reads JSONL requests from stdin, echoes back a matching JSON response line-by-line.
Only used by unit tests to exercise the long-lived stdin/stdout protocol.
"""
import json
import sys

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            method = request.get("method")
            params = request.get("params") or {}
            if method == "sleep":
                # Support delayed responses to test out-of-order behavior only in single-threaded mode.
                import time
                time.sleep(float(params.get("seconds", 0)))
                result = {"echo": params.get("value", "")}
            elif method == "exit":
                sys.exit(int(params.get("code", 0)))
            else:
                result = {"echo": params}
            response = {"id": request.get("id"), "ok": True, "result": result}
        except Exception as exc:
            response = {"id": None, "ok": False, "error": {"code": type(exc).__name__, "message": str(exc)}}
        print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == "__main__":
    main()
