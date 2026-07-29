# 会小纪匿名说话人分离 Sidecar

此程序只提供 **会议内匿名说话人分离**：输出 `SPEAKER_00` 等 cluster key 与时间区间。

- 不输出真实姓名；
- 不自动写入声纹库；
- `funasr` 是当前唯一生产候选，组合为 ASR + VAD + CAM++；
- `deterministic` 只用于协议测试，必须设置 `TINGLAN_DIARIZATION_TEST_BACKEND=1`；

## JSONL 方法

- `health`
- `preload`
- `diarize_file`
- `diarize_window`
- `embed_speaker`

stdout 仅输出 JSONL 响应。任何模型日志和 traceback 写入 stderr 或错误响应的 `trace` 字段。

## 本地验证

```sh
sh scripts/setup_voiceprint_sidecar.sh
"$HOME/Library/Application Support/会小纪/VoiceprintSidecar/.voiceprint-py312/bin/python" \
  Tools/voiceprint_sidecar/server.py --backend funasr --mode jsonl
```

然后向 stdin 发送 `health`、`preload` 和 `diarize_file` JSON 请求。

## 本地基准报告

`benchmark.py` 只读取本机 manifest 指向的分轨 WAV，输出匿名 speaker turn 的数量、覆盖率和跨轨重叠时长；不会输出转写文本或复制音频。

```sh
"$HOME/Library/Application Support/会小纪/VoiceprintSidecar/.voiceprint-py312/bin/python" \
  Tools/voiceprint_sidecar/benchmark.py \
  --manifest "$HOME/Library/Application Support/会小纪/Benchmarks/phase1-baseline.json" \
  --output "$HOME/Library/Application Support/会小纪/Benchmarks/phase1-baseline-report.json" \
  --python "$HOME/Library/Application Support/会小纪/VoiceprintSidecar/.voiceprint-py312/bin/python" \
  --server "$HOME/Library/Application Support/会小纪/VoiceprintSidecar/server.py"
```

manifest 示例（不应提交含用户音频路径的 manifest）：

```json
{
  "cases": [
    {
      "id": "meeting-001",
      "tracks": {
        "microphone": "/absolute/path/microphone.wav",
        "computer": "/absolute/path/computer.wav"
      }
    }
  ]
}
```

已有报告可直接生成标注模板，不会再次运行模型：

```sh
python Tools/voiceprint_sidecar/benchmark.py \
  --report-to-template "$HOME/Library/Application Support/会小纪/Benchmarks/phase1-baseline-report.json" \
  --truth-template "$HOME/Library/Application Support/会小纪/Benchmarks/phase1-truth-template.csv"
```
