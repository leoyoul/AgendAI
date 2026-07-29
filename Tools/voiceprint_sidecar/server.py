#!/usr/bin/env python3
"""会小纪本地说话人分离 sidecar。

协议：标准输入/输出一行一个 JSON。stdout 只输出协议 JSON；模型日志一律转到 stderr。

当前生产候选为 FunASR 的 ASR + VAD + CAM++ 组合：它只输出会议内匿名
speaker turns 与同模型 CAM++ embedding。它绝不输出或猜测真实姓名。
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.metadata
import io
import json
import os
import sys
import tempfile
import traceback
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

CODE_VERSION = "2026.07.10-p0"
TEST_BACKEND_ENV = "TINGLAN_DIARIZATION_TEST_BACKEND"


class SidecarError(RuntimeError):
    pass


def package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "not-installed"


def dependency_versions() -> dict[str, str]:
    return {
        "funasr": package_version("funasr"),
        "modelscope": package_version("modelscope"),
        "torch": package_version("torch"),
        "torchaudio": package_version("torchaudio"),
    }


def wav_duration_ms(path: str) -> int:
    with wave.open(path, "rb") as wav:
        frames = wav.getnframes()
        sample_rate = wav.getframerate() or 1
    return int(frames * 1000 / sample_rate)


def slice_pcm16_wav(path: str, start_ms: int, end_ms: int | None) -> tuple[str, int]:
    """返回切片临时 WAV 路径及相对原文件偏移；只支持会小纪落盘的 PCM16 WAV。"""
    with wave.open(path, "rb") as source:
        if source.getsampwidth() != 2:
            raise SidecarError("仅支持 16-bit PCM WAV，请先使用会小纪录音文件。")
        sample_rate = source.getframerate()
        start_frame = max(0, int(start_ms * sample_rate / 1000))
        total_frames = source.getnframes()
        requested_end = total_frames if end_ms is None else int(end_ms * sample_rate / 1000)
        end_frame = min(total_frames, max(start_frame, requested_end))
        source.setpos(start_frame)
        frames = source.readframes(end_frame - start_frame)
        params = source.getparams()

    handle = tempfile.NamedTemporaryFile(prefix="tinglan-diarization-", suffix=".wav", delete=False)
    handle.close()
    with wave.open(handle.name, "wb") as target:
        target.setparams(params)
        target.writeframes(frames)
    return handle.name, max(0, start_ms)


def normalize_embedding(value: Any) -> list[float]:
    """把 FunASR / torch 的 `spk_embedding` 规范为一维 Float 数组。"""
    if hasattr(value, "detach"):
        value = value.detach().cpu().float().tolist()
    while isinstance(value, list) and len(value) == 1 and isinstance(value[0], list):
        value = value[0]
    if not isinstance(value, list) or not value:
        raise SidecarError("CAM++ 未返回可用 speaker embedding。")
    try:
        return [float(item) for item in value]
    except (TypeError, ValueError) as exc:
        raise SidecarError("CAM++ speaker embedding 格式无效。") from exc


@dataclass
class DeterministicBackend:
    """只供协议测试使用；绝不允许作为生产结果。"""

    backend_id: str = "deterministic"

    def health(self) -> dict[str, Any]:
        return {
            "status": "ready",
            "backend": self.backend_id,
            "testOnly": True,
            "codeVersion": CODE_VERSION,
            "models": ["deterministic-diarization", "deterministic-embedding"],
            "dependencies": dependency_versions(),
        }

    def preload(self, _: str | None = None) -> dict[str, Any]:
        return self.health()

    def diarize_file(
        self,
        path: str,
        start_ms: int | None = None,
        end_ms: int | None = None,
        preset_spk_num: int | None = None,
    ) -> dict[str, Any]:
        duration = wav_duration_ms(path)
        start = max(0, start_ms or 0)
        end = min(duration, end_ms if end_ms is not None else duration)
        return {
            "turns": [] if end <= start else [
                {"startMs": start, "endMs": end, "speakerKey": "TEST_SPEAKER_00", "confidence": 0.0}
            ]
        }

    def embed_speaker(self, path: str, start_ms: int = 0, end_ms: int | None = None) -> dict[str, Any]:
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).digest()
        embedding = [((byte / 127.5) - 1.0) for byte in digest]
        return {"model": "deterministic-embedding", "embedding": embedding, "confidence": 0.0}


class FunASRBackend:
    """完整录音的匿名会议内 diarization 后端。

    由 FunASR 的 ASR、VAD、CAM++ 协同生成 `sentence_info[*].spk`。该结果只用于
    本次会议 speaker key，不负责已知人员身份匹配。
    """

    backend_id = "funasr"
    asr_model_id = os.environ.get("TINGLAN_FUNASR_ASR_MODEL", "paraformer-zh")
    vad_model_id = os.environ.get("TINGLAN_FUNASR_VAD_MODEL", "fsmn-vad")
    punc_model_id = os.environ.get("TINGLAN_FUNASR_PUNC_MODEL", "ct-punc-c")
    speaker_model_id = os.environ.get("TINGLAN_FUNASR_SPEAKER_MODEL", "cam++")

    def __init__(self) -> None:
        self.pipeline: Any | None = None
        self.embedding_model: Any | None = None
        self.device = os.environ.get("TINGLAN_FUNASR_DEVICE", "cpu")

    def health(self) -> dict[str, Any]:
        return {
            "status": "ready" if self.pipeline is not None and self.embedding_model is not None else "not_loaded",
            "backend": self.backend_id,
            "testOnly": False,
            "codeVersion": CODE_VERSION,
            "device": self.device,
            "models": [self.asr_model_id, self.vad_model_id, self.punc_model_id, self.speaker_model_id],
            "dependencies": dependency_versions(),
        }

    def preload(self, _: str | None = None) -> dict[str, Any]:
        try:
            from funasr import AutoModel
        except ImportError as exc:
            raise SidecarError("缺少 funasr 依赖；请运行 setup_voiceprint_sidecar.sh。") from exc

        # FunASR 与 ModelScope 的进度日志会污染 JSONL stdout，因此转到 stderr。
        with contextlib.redirect_stdout(sys.stderr):
            self.pipeline = AutoModel(
                model=self.asr_model_id,
                vad_model=self.vad_model_id,
                punc_model=self.punc_model_id,
                spk_model=self.speaker_model_id,
                device=self.device,
                disable_update=True,
            )
            self.embedding_model = AutoModel(
                model=self.speaker_model_id,
                device=self.device,
                disable_update=True,
            )
        return self.health()

    def diarize_file(
        self,
        path: str,
        start_ms: int | None = None,
        end_ms: int | None = None,
        preset_spk_num: int | None = None,
    ) -> dict[str, Any]:
        if self.pipeline is None:
            self.preload()

        offset_ms = 0
        input_path = path
        temporary_path: str | None = None
        if start_ms is not None or end_ms is not None:
            temporary_path, offset_ms = slice_pcm16_wav(path, start_ms or 0, end_ms)
            input_path = temporary_path

        try:
            with contextlib.redirect_stdout(sys.stderr):
                results = self.pipeline.generate(
                    input=input_path,
                    return_spk_res=True,
                    sentence_timestamp=True,
                    preset_spk_num=preset_spk_num,
                )
            turns = self._turns_from_results(results, offset_ms)
            return {"turns": turns}
        finally:
            if temporary_path:
                Path(temporary_path).unlink(missing_ok=True)

    def embed_speaker(self, path: str, start_ms: int = 0, end_ms: int | None = None) -> dict[str, Any]:
        if self.embedding_model is None:
            self.preload()

        temporary_path, _ = slice_pcm16_wav(path, start_ms, end_ms)
        try:
            with contextlib.redirect_stdout(sys.stderr):
                results = self.embedding_model.generate(input=temporary_path)
            if not results or "spk_embedding" not in results[0]:
                raise SidecarError("CAM++ 未返回 speaker embedding。")
            return {
                "model": self.speaker_model_id,
                "embedding": normalize_embedding(results[0]["spk_embedding"]),
                "confidence": 0.0,
            }
        finally:
            Path(temporary_path).unlink(missing_ok=True)

    @staticmethod
    def _turns_from_results(results: Any, offset_ms: int) -> list[dict[str, Any]]:
        turns: list[dict[str, Any]] = []
        for result in results or []:
            sentence_info = result.get("sentence_info") if isinstance(result, dict) else None
            if not sentence_info:
                continue
            for sentence in sentence_info:
                speaker = sentence.get("spk")
                start = sentence.get("start")
                end = sentence.get("end")
                if speaker is None or start is None or end is None:
                    continue
                start_ms = offset_ms + int(start)
                end_ms = offset_ms + int(end)
                if end_ms <= start_ms:
                    continue
                turns.append(
                    {
                        "startMs": start_ms,
                        "endMs": end_ms,
                        "speakerKey": f"SPEAKER_{int(speaker):02d}",
                        # FunASR 当前接口不提供经校准的 diarization confidence，不能伪造高分。
                        "confidence": 0.0,
                    }
                )

        if not turns:
            if results:
                raise SidecarError("FunASR 未返回可用的带说话人时间区间；不会伪造说话人分离结果。")
            return []

        turns.sort(key=lambda item: (item["startMs"], item["endMs"], item["speakerKey"]))
        merged: list[dict[str, Any]] = []
        for turn in turns:
            if (
                merged
                and merged[-1]["speakerKey"] == turn["speakerKey"]
                and turn["startMs"] - merged[-1]["endMs"] <= 600
            ):
                merged[-1]["endMs"] = max(merged[-1]["endMs"], turn["endMs"])
            else:
                merged.append(turn)
        return merged


def backend_for(name: str) -> Any:
    if name == "funasr":
        return FunASRBackend()
    if name == "deterministic":
        if os.environ.get(TEST_BACKEND_ENV) != "1":
            raise SidecarError("deterministic backend 仅允许测试环境使用。")
        return DeterministicBackend()
    raise SidecarError(f"不支持的 backend：{name}")


def handle_request(backend: Any, request: dict[str, Any]) -> dict[str, Any]:
    method = request.get("method")
    params = request.get("params") or {}
    if method == "health":
        return backend.health()
    if method == "preload":
        return backend.preload(params.get("hfToken"))
    if method == "diarize_file":
        preset_spk_num = params.get("numSpeakers")
        return backend.diarize_file(
            str(params["path"]),
            preset_spk_num=int(preset_spk_num) if preset_spk_num is not None else None,
        )
    if method == "diarize_window":
        preset_spk_num = params.get("numSpeakers")
        return backend.diarize_file(
            str(params["path"]),
            int(params["startMs"]),
            int(params["endMs"]),
            preset_spk_num=int(preset_spk_num) if preset_spk_num is not None else None,
        )
    if method == "embed_speaker":
        return backend.embed_speaker(
            str(params["path"]),
            int(params.get("startMs", 0)),
            int(params["endMs"]) if params.get("endMs") is not None else None,
        )
    raise SidecarError(f"未知 sidecar 方法：{method}")


def response_error(raw_line: str, exc: Exception) -> dict[str, Any]:
    request_id: Any = None
    try:
        request_id = json.loads(raw_line).get("id")
    except Exception:
        pass
    trace = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__, limit=4)).strip()
    return {
        "id": request_id,
        "ok": False,
        "error": {"code": exc.__class__.__name__, "message": str(exc), "trace": trace[-4000:]},
    }


def run_jsonl(backend: Any) -> None:
    for raw_line in sys.stdin:
        if not raw_line.strip():
            continue
        try:
            request = json.loads(raw_line)
            response = {"id": request.get("id"), "ok": True, "result": handle_request(backend, request)}
        except Exception as exc:
            response = response_error(raw_line, exc)
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="会小纪本地匿名说话人分离 JSONL sidecar")
    parser.add_argument("--mode", choices=["jsonl"], default="jsonl")
    parser.add_argument("--backend", choices=["funasr", "deterministic"], default="funasr")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    backend = backend_for(args.backend)
    run_jsonl(backend)


if __name__ == "__main__":
    main()
