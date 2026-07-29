#!/usr/bin/env python3
"""Test sidecar that writes carriage-return progress noise before its JSON response."""

from __future__ import annotations

import json
import sys


for raw_line in sys.stdin:
    request = json.loads(raw_line)
    sys.stdout.write("progress 0%\rprogress 100%\r")
    sys.stdout.flush()
    print(json.dumps({"id": request.get("id"), "ok": True, "result": {"value": "ok"}}), flush=True)
