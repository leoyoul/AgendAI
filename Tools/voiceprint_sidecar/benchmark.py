#!/usr/bin/env python3
"""对本地匿名说话人分离生成可复现基线报告。

音频和 manifest 默认放在 Application Support 等本机私有目录；本工具只输出
speaker turn 的聚合统计，不把转写文本或音频内容写入报告。
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
import wave
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class BenchmarkError(RuntimeError):
    pass


def request(process: subprocess.Popen[str], request_id: int, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params or {}}, ensure_ascii=False) + "\n")
    process.stdin.flush()
    response_line = process.stdout.readline()
    if not response_line:
        raise BenchmarkError("sidecar 没有返回 JSONL 响应。")
    response = json.loads(response_line)
    if not response.get("ok"):
        error = response.get("error") or {}
        raise BenchmarkError(error.get("message") or "sidecar 返回未知错误。")
    return response["result"]


def wav_duration_ms(path: Path) -> int:
    try:
        with wave.open(str(path), "rb") as source:
            return round(source.getnframes() * 1000 / max(source.getframerate(), 1))
    except wave.Error as exc:
        raise BenchmarkError(f"无法读取 WAV：{path}：{exc}") from exc


def union_duration_ms(turns: list[dict[str, Any]]) -> int:
    ranges = sorted(
        (max(0, int(turn["startMs"])), max(0, int(turn["endMs"])))
        for turn in turns
        if int(turn["endMs"]) > int(turn["startMs"])
    )
    total = 0
    current_start: int | None = None
    current_end: int | None = None
    for start, end in ranges:
        if current_start is None:
            current_start, current_end = start, end
        elif start <= current_end:
            current_end = max(current_end, end)
        else:
            total += current_end - current_start
            current_start, current_end = start, end
    if current_start is not None and current_end is not None:
        total += current_end - current_start
    return total


def validate_turns(turns: Any, track: str) -> list[dict[str, Any]]:
    if not isinstance(turns, list):
        raise BenchmarkError(f"{track} 返回的 turns 不是数组。")
    normalized: list[dict[str, Any]] = []
    for turn in turns:
        if not isinstance(turn, dict):
            raise BenchmarkError(f"{track} 包含非对象 turn。")
        start = int(turn.get("startMs", -1))
        end = int(turn.get("endMs", -1))
        speaker = str(turn.get("speakerKey", "")).strip()
        if start < 0 or end <= start or not speaker:
            raise BenchmarkError(f"{track} 包含无效 turn：{turn}")
        normalized.append(
            {
                "startMs": start,
                "endMs": end,
                "speakerKey": speaker,
                "confidence": float(turn.get("confidence", 0)),
            }
        )
    return normalized


def cross_track_overlap_ms(track_turns: dict[str, list[dict[str, Any]]]) -> int:
    microphone = track_turns.get("microphone", [])
    computer = track_turns.get("computer", [])
    overlaps: list[tuple[int, int]] = []
    for left in microphone:
        for right in computer:
            start = max(left["startMs"], right["startMs"])
            end = min(left["endMs"], right["endMs"])
            if end > start:
                overlaps.append((start, end))
    return union_duration_ms([{"startMs": start, "endMs": end} for start, end in overlaps])


def track_report(path: Path, turns: list[dict[str, Any]]) -> dict[str, Any]:
    duration = wav_duration_ms(path)
    speech = union_duration_ms(turns)
    return {
        "durationMs": duration,
        "turnCount": len(turns),
        "speakerCount": len({turn["speakerKey"] for turn in turns}),
        "speakerKeys": sorted({turn["speakerKey"] for turn in turns}),
        "speechDurationMs": speech,
        "speechCoverage": round(speech / duration, 4) if duration else 0,
        "turns": turns,
    }


def write_truth_template(report_cases: list[dict[str, Any]], destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "caseId", "track", "startMs", "endMs", "modelSpeakerKey",
                "truthSpeaker", "reviewStatus", "notes"
            ],
        )
        writer.writeheader()
        for case in report_cases:
            for track, data in case["tracks"].items():
                for turn in data["turns"]:
                    writer.writerow({
                        "caseId": case["id"],
                        "track": track,
                        "startMs": turn["startMs"],
                        "endMs": turn["endMs"],
                        "modelSpeakerKey": turn["speakerKey"],
                        "truthSpeaker": "",
                        "reviewStatus": "pending",
                        "notes": "",
                    })


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description="生成会小纪匿名分离基线报告")
    parser.add_argument("--manifest", type=Path, help="本机 JSON manifest，包含 cases[].tracks")
    parser.add_argument("--output", type=Path, help="输出 JSON 报告路径")
    parser.add_argument("--report-to-template", type=Path, help="从已有基线报告生成真值标注模板，不重新跑模型")
    parser.add_argument("--python", type=Path, default=root / ".voiceprint-py312" / "bin" / "python")
    parser.add_argument("--server", type=Path, default=root / "Tools" / "voiceprint_sidecar" / "server.py")
    parser.add_argument("--backend", choices=["funasr", "deterministic"], default="funasr")
    parser.add_argument("--truth-template", type=Path, help="可选：输出不含转写文本的人工真值标注 CSV")
    parser.add_argument("--device", default="cpu", help="FunASR device，例如 cpu 或 mps")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.report_to_template:
        if not args.truth_template:
            raise BenchmarkError("使用 --report-to-template 时必须提供 --truth-template。")
        report = json.loads(args.report_to_template.read_text(encoding="utf-8"))
        cases = report.get("cases")
        if not isinstance(cases, list):
            raise BenchmarkError("基线报告缺少 cases 数组。")
        write_truth_template(cases, args.truth_template)
        print(f"已生成真值标注模板：{args.truth_template}")
        return
    if not args.manifest or not args.output:
        raise BenchmarkError("请同时提供 --manifest 和 --output，或使用 --report-to-template。")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise BenchmarkError("manifest 必须提供非空 cases 数组。")
    if not args.python.is_file() or not args.server.is_file():
        raise BenchmarkError("找不到 Python 或 sidecar server.py。")

    environment = {
        **os.environ,
        "TINGLAN_FUNASR_DEVICE": args.device,
    }
    process = subprocess.Popen(
        [str(args.python), str(args.server), "--backend", args.backend, "--mode", "jsonl"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=None,
        text=True,
        env=environment,
    )
    try:
        health = request(process, 1, "health")
        request(process, 2, "preload")
        report_cases: list[dict[str, Any]] = []
        request_id = 3
        for case in cases:
            case_id = str(case.get("id", "")).strip()
            tracks = case.get("tracks")
            if not case_id or not isinstance(tracks, dict):
                raise BenchmarkError("每个 case 必须包含 id 和 tracks。")
            report_tracks: dict[str, Any] = {}
            normalized_turns: dict[str, list[dict[str, Any]]] = {}
            for track in ("microphone", "computer"):
                raw_path = tracks.get(track)
                if not raw_path:
                    continue
                path = Path(raw_path)
                if not path.is_file():
                    raise BenchmarkError(f"{case_id} 的 {track} 音频不存在：{path}")
                result = request(process, request_id, "diarize_file", {"path": str(path)})
                request_id += 1
                turns = validate_turns(result.get("turns"), track)
                normalized_turns[track] = turns
                report_tracks[track] = track_report(path, turns)
            if not report_tracks:
                raise BenchmarkError(f"{case_id} 没有可用的 microphone/computer 音轨。")
            report_cases.append(
                {
                    "id": case_id,
                    "tracks": report_tracks,
                    "crossTrackOverlapMs": cross_track_overlap_ms(normalized_turns),
                }
            )

        report = {
            "formatVersion": 1,
            "generatedAt": datetime.now(UTC).isoformat(),
            "sourceManifest": str(args.manifest),
            "backend": args.backend,
            "health": health,
            "cases": report_cases,
            "note": "本报告不含转写文本或音频内容；没有人工真值时，只能作为可重复的匿名分离基线，不能代表准确率。",
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"已生成基线报告：{args.output}")
        if args.truth_template:
            write_truth_template(report_cases, args.truth_template)
            print(f"已生成真值标注模板：{args.truth_template}")
    finally:
        if process.stdin:
            process.stdin.close()
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)


if __name__ == "__main__":
    try:
        main()
    except BenchmarkError as exc:
        print(f"基准失败：{exc}", file=sys.stderr)
        raise SystemExit(1)
