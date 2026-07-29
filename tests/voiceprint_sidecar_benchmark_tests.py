import json
import os
import subprocess
import tempfile
import unittest
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "Tools" / "voiceprint_sidecar" / "benchmark.py"
SERVER = ROOT / "Tools" / "voiceprint_sidecar" / "server.py"
PYTHON = ROOT / ".voiceprint-py312" / "bin" / "python"


class VoiceprintSidecarBenchmarkTests(unittest.TestCase):
    def test_benchmark_writes_anonymous_stats_without_audio_content(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tinglan-benchmark-test-") as directory:
            root = Path(directory)
            wav_path = root / "track.wav"
            with wave.open(str(wav_path), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16_000)
                wav.writeframes(b"\0\0" * 16_000)
            manifest = root / "manifest.json"
            output = root / "report.json"
            template = root / "truth-template.csv"
            manifest.write_text(
                json.dumps({"cases": [{"id": "case-1", "tracks": {"microphone": str(wav_path)}}]}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    str(PYTHON), str(TOOL),
                    "--manifest", str(manifest),
                    "--output", str(output),
                    "--python", str(PYTHON),
                    "--server", str(SERVER),
                    "--backend", "deterministic",
                    "--truth-template", str(template),
                ],
                text=True,
                capture_output=True,
                env={**os.environ, "TINGLAN_DIARIZATION_TEST_BACKEND": "1"},
                check=True,
            )
            self.assertIn("已生成基线报告", result.stdout)
            self.assertIn("已生成真值标注模板", result.stdout)
            report = json.loads(output.read_text(encoding="utf-8"))
            track = report["cases"][0]["tracks"]["microphone"]
            self.assertEqual(track["durationMs"], 1_000)
            self.assertEqual(track["speakerCount"], 1)
            self.assertEqual(track["speakerKeys"], ["TEST_SPEAKER_00"])
            self.assertNotIn("audio", track)
            self.assertNotIn("text", track)
            template_text = template.read_text(encoding="utf-8")
            self.assertIn("modelSpeakerKey,truthSpeaker,reviewStatus,notes", template_text)
            self.assertIn("TEST_SPEAKER_00", template_text)


    def test_truth_template_reuses_existing_report_turns(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tinglan-benchmark-template-") as directory:
            root = Path(directory)
            report = root / "report.json"
            template = root / "template.csv"
            report.write_text(json.dumps({
                "cases": [{
                    "id": "case-report",
                    "tracks": {
                        "computer": {"turns": [{"startMs": 10, "endMs": 20, "speakerKey": "SPEAKER_07"}]}
                    }
                }]
            }), encoding="utf-8")
            subprocess.run(
                [str(PYTHON), str(TOOL), "--report-to-template", str(report), "--truth-template", str(template)],
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("SPEAKER_07", template.read_text(encoding="utf-8"))



if __name__ == "__main__":
    unittest.main()
