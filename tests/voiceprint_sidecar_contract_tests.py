import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "Tools" / "voiceprint_sidecar" / "server.py"
REQUIREMENTS = ROOT / "Tools" / "voiceprint_sidecar" / "requirements.txt"
SETUP = ROOT / "scripts" / "setup_voiceprint_sidecar.sh"
PYTHON = ROOT / ".voiceprint-py312" / "bin" / "python"


def load_sidecar_module():
    spec = importlib.util.spec_from_file_location("tinglan_voiceprint_sidecar", SERVER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def request(process: subprocess.Popen[str], request_id: int, method: str, params: dict | None = None) -> dict:
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr else ""
        raise AssertionError(f"sidecar 未返回 JSONL 响应：{stderr}")
    return json.loads(line)


class VoiceprintSidecarContractTests(unittest.TestCase):
    def test_installer_pins_pytorch_runtime_dependencies(self) -> None:
        requirements = {
            line.strip()
            for line in REQUIREMENTS.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertIn("torch==2.12.1", requirements)
        self.assertIn("torchaudio==2.11.0", requirements)
        setup = SETUP.read_text(encoding="utf-8")
        self.assertIn("sidecar 运行依赖安装不完整", setup)
        self.assertIn("import torch", setup)
        self.assertIn("import torchaudio", setup)

    def test_funasr_rejects_structured_result_without_usable_speaker_turn(self) -> None:
        sidecar = load_sidecar_module()
        backend = sidecar.FunASRBackend()
        with self.assertRaisesRegex(sidecar.SidecarError, "不会伪造说话人分离结果"):
            backend._turns_from_results(
                [{"sentence_info": [{"start": 0, "end": 1000, "text": "测试"}]}],
                offset_ms=0,
            )

    def test_deterministic_backend_requires_explicit_test_environment(self) -> None:
        result = subprocess.run(
            [str(PYTHON), str(SERVER), "--backend", "deterministic", "--mode", "jsonl"],
            input='{"id":1,"method":"health","params":{}}\n',
            text=True,
            capture_output=True,
            env={**os.environ, "TINGLAN_DIARIZATION_TEST_BACKEND": ""},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("仅允许测试环境", result.stderr)

    def test_deterministic_jsonl_contract(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
            wav_path = Path(handle.name)
        try:
            with wave.open(str(wav_path), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16_000)
                wav.writeframes(b"\0\0" * 16_000)
            process = subprocess.Popen(
                [str(PYTHON), str(SERVER), "--backend", "deterministic", "--mode", "jsonl"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "TINGLAN_DIARIZATION_TEST_BACKEND": "1"},
            )
            health = request(process, 1, "health")
            self.assertTrue(health["ok"])
            self.assertTrue(health["result"]["testOnly"])
            turns = request(process, 2, "diarize_file", {"path": str(wav_path)})
            self.assertTrue(turns["ok"])
            self.assertEqual(turns["result"]["turns"][0]["speakerKey"], "TEST_SPEAKER_00")
            embedding = request(process, 3, "embed_speaker", {"path": str(wav_path), "startMs": 0, "endMs": 1_000})
            self.assertTrue(embedding["ok"])
            self.assertTrue(embedding["result"]["embedding"])
            assert process.stdin is not None
            process.stdin.close()
            self.assertEqual(process.wait(timeout=10), 0)
            assert process.stdout is not None and process.stderr is not None
            process.stdout.close()
            process.stderr.close()
        finally:
            wav_path.unlink(missing_ok=True)

    def test_jsonl_forwards_fixed_speaker_count_to_funasr_backend(self) -> None:
        sidecar = load_sidecar_module()

        class CapturingBackend:
            def diarize_file(self, path: str, preset_spk_num: int | None = None) -> dict:
                return {"path": path, "preset_spk_num": preset_spk_num}

        result = sidecar.handle_request(
            CapturingBackend(),
            {
                "method": "diarize_file",
                "params": {"path": "/tmp/meeting.wav", "numSpeakers": 4},
            },
        )
        self.assertEqual(result["preset_spk_num"], 4)


if __name__ == "__main__":
    unittest.main()
