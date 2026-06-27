# AI Performance Test

This is a disposable implementation of the plan in
`docs/ai-assistant-perf-test-plan.md`. It is intentionally not ArgoCD-managed
and is not production-ready.

It deploys:

- NeMo CPU ASR with `nvidia/stt_en_fastconformer_hybrid_large_streaming_multi`.
- llama.cpp server with `Qwen/Qwen3-1.7B-GGUF` and
  `Qwen3-1.7B-Q8_0.gguf`.
- Pocket TTS wrapped in a tiny Python HTTP service.
- One client Job that runs the benchmark and writes result files.

The service Deployments use `strategy.type: Recreate`. This is intentional:
the test has no HA requirement, and the single-node cluster cannot reliably fit
old and replacement model-serving pods at the same time.

The namespace is temporary, but cache PVCs use `zfs-bulk` so model downloads can
survive repeated Job runs while you are testing.

## Input WAV

Create a ConfigMap named `ai-perf-input` with a key named `input.wav`.

The realtime ASR path expects PCM16 WAV. The client converts mono/stereo PCM16
to a 16 kHz mono PCM stream for the NeMo websocket service. If realtime fails,
the client falls back to the NeMo HTTP transcription endpoint.
After the WAV frames are replayed, the client appends a bounded silence tail
(`ASR_TRAILING_SILENCE_MS`, default 500 ms), then commits the ASR buffer.

```sh
kubectl create namespace ai-perf-test --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ai-perf-test delete configmap ai-perf-input --ignore-not-found
kubectl -n ai-perf-test create configmap ai-perf-input \
  --from-file=input.wav=/path/to/input.wav
```

## Run

Apply the experiment:

```sh
kubectl apply -k experiments/ai-perf-test
```

Watch pods:

```sh
kubectl -n ai-perf-test get pods -w
```

Watch the benchmark log:

```sh
kubectl -n ai-perf-test logs -f job/ai-perf-client
```

Before the measured path starts, the client waits for the NeMo ASR model to be
loaded, warms STT with the same WAV, sends a simple
llama.cpp prompt, and warms TTS with a short `hello`. Look for
`asr_model_ready`, `stt_warmup_complete`, `llm_warmup_complete`, and
`tts_warmup_complete` events near the start of the Job log.
The generated scripts ConfigMap keeps Kustomize's content hash enabled. This is
intentional: if `run_benchmark.py`, `nemo_asr_server.py`, or `tts_server.py` changes, Kubernetes must
roll the pod template instead of leaving a running Python process on the old
script. The client also requires the TTS `/health` response to advertise
`streaming: true`, so an old TTS pod will not be accepted as ready.

## Results

The client writes results under `/results/run-YYYYMMDD-HHMMSS/` on the
`ai-perf-results` PVC:

- `events.jsonl`
- `summary.json`
- `transcript.txt`
- `response.txt`
- `response-raw.txt`
- `response.wav`
- `tts-warmup.wav`
- `tts-baseline.wav`

In `summary.json`, treat `llm_cache_comparison_valid` as the gate for comparing
`cold_final_ttft_ms` and `cached_final_ttft_ms`. The llama.cpp Deployment uses
`--parallel 4`; the client assigns separate slots for warm-up, cold baseline,
cached baseline, and full pipeline, and includes the run id in prompts so state
from earlier runs cannot accidentally match.
The prompt includes `/no_think` plus an empty Qwen assistant prefill
`<think></think>` to avoid spending measured decode time on Qwen thinking
tokens. The client only trims that exact adapter prefix and protocol sentinel
tokens if the server returns them in the completion text; it does not remove
generated reasoning or replace bad model output with a nicer response. The raw
LLM completion is saved as `response-raw.txt`.

The full pipeline streams the LLM response into Pocket TTS after the first
sentence boundary. Pocket TTS returns raw PCM chunks from
`/synthesize_stream`; the client records the first playable audio chunk, then
stitches the streamed segments into `response.wav`. If the tail segment is not
ready by the time the first segment would finish playing, the saved WAV includes
the simulated playback gap and the summary reports it.

For user-perceived response start, prefer
`full_pipeline_first_audio_chunk_from_audio_end_ms`. The older
`full_pipeline_spoken_response_from_audio_end_ms` is kept as the same
first-audio value for compatibility. Completion-oriented fields are separate:
`full_pipeline_tts_generation_done_from_audio_end_ms` records when all response
audio chunks were generated, and
`full_pipeline_playback_complete_from_audio_end_ms` records simulated playback
completion. The `tts_input_*` fields report the first-sentence vs tail split,
including text, audio, and generation ratios.

Likewise, audio-end latency fields are only populated when the full pipeline
used realtime ASR. If NeMo ASR falls back to HTTP transcription,
`full_pipeline_audio_end_reference_valid` is `false` and audio-end latency
fields are set to `null`.
Check `full_pipeline_cache_warm_timing` before treating the full-pipeline cache
warm as incremental. Only `incremental_asr_delta` means the LLM was warmed from
transcript data that arrived during realtime ASR. `none_no_realtime_delta`
means the ASR service only produced a completed transcript, and
`none_http_fallback` means the benchmark used HTTP transcription after realtime
failed.

The NeMo ASR service owns only STT; the benchmark client owns the LLM and TTS
path. The websocket path uses FastConformer's cache-aware streaming decoder:
incoming PCM is kept as a continuous raw stream, newly stable feature frames are
appended to NeMo's streaming audio buffer, and those features are decoded through
`conformer_stream_step` while preserving encoder caches and previous RNNT
hypotheses between chunks. The strategy is labeled
`cache_aware_conformer_stream_step_continuous_features` in `/health`, events,
and summary output. A realtime `completed` transcript is treated as the
assistant turn transcript. If
that transcript differs from the STT warm-up HTTP transcript,
`asr_matches_stt_warmup` or `full_pipeline_asr_matches_stt_warmup` will be
`false`; the client does not merge later ASR segments to hide that failure.
If realtime still does not complete after the silence tail plus
`ASR_COMPLETION_GRACE_MS`, the client falls back to HTTP and marks
audio-end-relative metrics invalid.

Copy results out with:

```sh
kubectl -n ai-perf-test wait --for=condition=Ready pod/ai-perf-results-reader --timeout=120s
kubectl -n ai-perf-test cp ai-perf-results-reader:/results ./tmp/ai-perf-test-results
```

`kubectl cp` requires a running container because it shells into the source pod.
The benchmark Job pod is usually already `Succeeded` by the time results are
copied, so the kustomization includes `Pod/ai-perf-results-reader` mounted
read-only on the same results PVC.

## Rerun

Delete the Job and the results-reader pod, then apply again. Keep the namespace
and PVCs if you want to reuse downloaded model caches. The results-reader is a
plain pod, so changes to its spec are immutable while it already exists.

```sh
kubectl -n ai-perf-test delete job ai-perf-client --ignore-not-found
kubectl -n ai-perf-test delete pod ai-perf-results-reader --ignore-not-found
kubectl apply -k experiments/ai-perf-test
```

To change the input WAV:

```sh
kubectl -n ai-perf-test delete configmap ai-perf-input --ignore-not-found
kubectl -n ai-perf-test create configmap ai-perf-input \
  --from-file=input.wav=/path/to/other.wav
kubectl -n ai-perf-test delete job ai-perf-client --ignore-not-found
kubectl -n ai-perf-test delete pod ai-perf-results-reader --ignore-not-found
kubectl apply -k experiments/ai-perf-test
```

## Cleanup

When done, delete the namespace. Because `zfs-bulk` uses retained volumes, check
for released PVs afterward and remove them manually if you do not want the model
caches anymore.

```sh
kubectl delete namespace ai-perf-test
kubectl get pv
```

## Notes

- No Ingress, TLS, auth, autoscaling, dashboards, or backup resources are
  included.
- The TTS deployment still uses the historical `chatterbox-tts` Kubernetes
  object and service names so `kubectl apply -k` rolls the old pod in place.
  The actual backend is Pocket TTS.
- NeMo ASR, llama.cpp, and TTS use Recreate rollouts to avoid resource
  contention during one-off manifest changes.
- The benchmark pods intentionally do not set CPU or memory requests/limits.
  On this single-node test cluster, fixed pod resources can block scheduling and
  add noise without improving the measurement.
- `speaches.yaml` is left in the directory as a shelved baseline manifest, but
  it is not included by `kustomization.yaml`.
- The TTS pod creates `/cache/pocket-tts-venv` and installs Python dependencies
  there on first startup. This is deliberate for a one-off test; the first run
  can be slow, but reruns should reuse the PVC cache.
- The NeMo ASR pod creates `/cache/nemo-asr-venv` and installs CPU PyTorch plus
  `nemo_toolkit[asr]` there on first startup. The first startup can be slow.
- The llama.cpp model is set in `llama-server.yaml`. Edit `--hf-repo` and
  `--hf-file` there if the selected GGUF repo or file needs to change.
