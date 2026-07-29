"""可选的真实 FunASR smoke；不读取用户会议录音，也不把合成音色分离结果当准确率结论。"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "Tools" / "voiceprint_sidecar" / "server.py"
PYTHON = ROOT / ".voiceprint-py312" / "bin" / "python"


def request(process: subprocess.Popen[str], request_id: int, method: str, params: dict | None = None) -> dict:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n")
    process.stdin.flush()
    return json.loads(process.stdout.readline())


class FunASRSmokeTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("say") and shutil.which("afconvert"), "需要 macOS say 与 afconvert")
    def test_funasr_returns_anonymous_turn_contract_for_synthetic_voice(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tinglan-funasr-smoke-") as directory:
            root = Path(directory)
            aiff = root / "voice.aiff"
            wav = root / "voice.wav"
            subprocess.run(["say", "-v", "Tingting", "-o", str(aiff), "大家好，今天我们讨论项目进度。"], check=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(aiff), str(wav)], check=True)
            process = subprocess.Popen(
                [str(PYTHON), str(SERVER), "--backend", "funasr", "--mode", "jsonl"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "TINGLAN_FUNASR_DEVICE": "cpu"},
            )
            health = request(process, 1, "health")
            self.assertTrue(health["ok"])
            self.assertFalse(health["result"]["testOnly"])
            preload = request(process, 2, "preload")
            self.assertTrue(preload["ok"], preload)
            diarization = request(process, 3, "diarize_file", {"path": str(wav)})
            self.assertTrue(diarization["ok"], diarization)
            for turn in diarization["result"]["turns"]:
                self.assertTrue(turn["speakerKey"].startswith("SPEAKER_"))
                self.assertGreater(turn["endMs"], turn["startMs"])
                self.assertEqual(turn["confidence"], 0.0)
            assert process.stdin is not None
            process.stdin.close()
            self.assertEqual(process.wait(timeout=120), 0)
            assert process.stdout is not None and process.stderr is not None
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
