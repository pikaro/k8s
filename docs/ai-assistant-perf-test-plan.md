# AI Assistant Performance Test Plan

This is a one-off benchmark harness for proving the basic voice-to-text-to-LLM
cache-warming idea on this cluster. It may be re-run with small modifications,
but it is not a platform service and should not be made production-ready.

The only required output is a small set of timing numbers that show whether
streamed transcript chunks can warm an LLM session slot so the final submit has
lower time to first token.

## Goal

Build a disposable Kubernetes test setup for this flow:

```text
WAV playback
  -> NeMo / FastConformer ASR websocket transcription
  -> chunked text
  -> local LLM inference cache warm requests
  -> retained slot / prompt cache
  -> final submit on the same slot
  -> reduced final TTFT
  -> Pocket TTS
  -> spoken WAV response
```

The test should answer these questions:

- Can the cluster run the ASR and small local LLM pipeline at the same time?
- Is ASR faster than, equal to, or slower than realtime for the selected WAV?
- Does warming the same LLM slot while transcript chunks arrive reduce final
  TTFT compared with a cold final prompt?
- Can the generated chat response be synthesized to speech on the current
  CPU-only node?
- What is the end-to-end latency shape for this rough assistant pipeline?

## Non-Goals

Do not build any of the following for this test:

- Web UI.
- Public Ingress, DNS, TLS, auth, or user accounts.
- ArgoCD catalog entries or long-lived GitOps ownership.
- Helm chart polish.
- Autoscaling, HA, PodDisruptionBudgets, network policies, or hardening.
- Prometheus/Grafana dashboards.
- Durable backups.
- Generic model-serving abstraction.
- Full-duplex speech interaction, barge-in, interruption handling, or realtime
  playback integration.

Direct `kubectl apply` into a temporary namespace is acceptable. Runtime model
downloads are acceptable. Floating image tags are acceptable if the exact image
tags and model IDs are recorded in the result file.

## Current Cluster Assumptions

The first pass targets the current single-node Talos cluster:

- One ready amd64 control-plane node.
- About 12 vCPU and 62 GiB allocatable memory.
- No GPU resources advertised.
- OpenEBS/ZFS storage classes are available. The implementation uses
  `zfs-bulk` so model caches can survive repeated Job runs while this temporary
  benchmark namespace is kept around.
- Metrics-server is not available, so the harness must collect its own timing
  data instead of relying on `kubectl top`.

If this is re-run after adding GPU support, keep the same harness shape and only
change the images, accelerator-specific scheduling, and model choices.

Pocket TTS is included as the spoken-response synthesis component. It is a
small CPU-oriented model, so it is a better fit for the current hardware than
Chatterbox-Turbo. It still should be interpreted as a measured component in
this one-off harness, not as production TTS validation.

## Test Namespace

Use one disposable namespace:

```text
ai-perf-test
```

Expected objects:

- `Deployment/nemo-asr`
- `Service/nemo-asr`
- `Deployment/llama-server`
- `Service/llama-server`
- `Deployment/chatterbox-tts`
- `Service/chatterbox-tts`
- `Job/ai-perf-client`
- `Pod/ai-perf-results-reader`
- Optional PVCs for model caches

The service Deployments should use `strategy.type: Recreate`. There is no HA
requirement for this benchmark, and Recreate avoids temporarily scheduling two
large model-serving pods during image, command, or resource changes.

Cleanup should be a namespace delete:

```sh
kubectl delete namespace ai-perf-test
```

## Components

### NeMo FastConformer ASR

Use NeMo as the STT server:

```text
image: python:3.11-bookworm + CPU PyTorch + nemo_toolkit[asr]
port: 8002
model: nvidia/stt_en_fastconformer_hybrid_large_streaming_multi
```

Suggested environment:

```text
ASR_DEVICE=cpu
ASR_TORCH_THREADS=4
ASR_DECODER_TYPE=rnnt
ASR_ATT_CONTEXT_SIZE=[70,1]
ASR_INPUT_AUDIO_SECONDS=0.25
ASR_FINAL_FLUSH_SECONDS=0.25
ASR_PREPROCESS_HOLDBACK_SECONDS=0.1
ASR_STREAM_SAMPLE_RATE=16000
```

Use the local NeMo wrapper in transcription-only mode. The client replays audio
at wall-clock speed over the ASR websocket as 16 kHz mono PCM16, then commits
the buffer after a bounded silence tail. The wrapper exposes the same
benchmark-facing HTTP and websocket shape for FastConformer now and future
Parakeet experiments later.

The websocket path uses NeMo cache-aware streaming: incoming PCM is kept as a
continuous raw stream, newly stable feature frames are appended to a
`CacheAwareStreamingAudioBuffer`, then decoded with `conformer_stream_step`
while carrying encoder cache state and previous RNNT hypotheses between chunks.
The service labels this strategy as
`cache_aware_conformer_stream_step_continuous_features` in `/health`, events,
and summary output. The HTTP endpoint remains available as the offline
transcription baseline.

### LLM Server

Use llama.cpp first because the current node has CPU only and llama.cpp exposes
simple slot and prompt-cache behavior.

```text
image: ghcr.io/ggml-org/llama.cpp:server
port: 8080
initial model: Qwen3-1.7B GGUF, Q4-class quant
second model, if useful: Qwen3-4B GGUF, Q4-class quant
```

Suggested server arguments:

```text
--host 0.0.0.0
--port 8080
--ctx-size 8192
--parallel 4
--threads 8
--threads-batch 8
--cache-prompt
--slots
--slot-save-path /models
--metrics
--no-webui
```

The exact model source can be changed per run. Record it in the output.

Important limitation: llama.cpp prompt caching is a practical stand-in here, not
a custom prefill-only API. The first implementation should try a zero-token
cache warm request if supported. If that does not populate the slot/cache, use a
one-token request, discard the token, and record that cache-warm latency includes
one decode token.

The server should expose at least four slots: warm-up, cold baseline, cached
baseline, and full pipeline. The benchmark uses distinct slots plus a per-run
prompt id instead of depending on slot erase actions, because some llama.cpp
server builds reject erase unless additional slot-save support is enabled.

### Client Job

Use one Python client Job to coordinate the whole run.

Inputs:

- One WAV file.
- Test case name.
- ASR model ID.
- LLM model ID.
- TTS model ID.
- LLM slot ID, fixed to `0` for the basic run.
- Chunk size, for example 100-250 ms audio frames.
- Transcript stabilization policy.

Outputs:

- JSONL event log.
- Final JSON summary.
- Optional plain text transcript.

The Job can install Python dependencies at startup. That is intentionally not
production-grade, but it keeps this benchmark small and easy to modify.

The TTS Deployment and Service retain the historical `chatterbox-tts` names so
`kubectl apply -k` updates the existing workload in place instead of leaving an
old Chatterbox pod running beside Pocket TTS.

### Pocket TTS

Use Pocket TTS as the final spoken-response generator:

```text
package: pocket-tts
model: kyutai/pocket-tts
language: English
port: 8001, if wrapped as a tiny HTTP service
```

Pocket TTS is a small CPU-oriented TTS model. Use the default English model and
the built-in `alba` voice for this one-off run.

The implementation is a tiny Python HTTP wrapper around
`TTSModel.load_model(language="english")` plus
`get_state_for_audio_prompt("alba")` with `/synthesize` and
`/synthesize_stream` endpoints:

```json
{"text":"Short assistant answer."}
```

The non-streaming endpoint returns a complete WAV and is useful for warm-up and
baseline checks. The streaming endpoint returns raw PCM chunks from
`TTSModel.generate_audio_stream()`. The client starts TTS after the first LLM
sentence boundary, continues collecting the rest of the LLM response, and then
synthesizes the tail as a second segment. Playback timing is simulated from the
first audio chunk timestamp and generated audio durations, so the benchmark can
report first-audio latency and any tail playback gap separately.

A fixed built-in/default voice is fine for the first run. If a reference voice
is used, store the short reference WAV in the client image, ConfigMap, or
temporary test PVC; do not introduce secret or media-management machinery for
this benchmark.

The assistant will normally speak even when the real result is an MCP call. This
benchmark does not need MCP at all: the LLM should answer as ordinary chat, and
the generated answer should be streamed into TTS at natural text boundaries.

## Execution Flow

### 1. Start Services

Apply the namespace, Deployments, Services, and optional PVCs.

Wait for:

- `nemo-asr` `/health` to return ready with `streaming: true`.
- `llama-server` `/health` to return ready.
- `chatterbox-tts` `/health` to return ready, if wrapped as a service.
- The requested ASR and LLM models to be loaded or downloaded.
  Pocket TTS should also be loaded before measured runs if practical.

The client should issue one explicit warm-up request to each service before
starting measured runs. Warm-up timings are recorded but excluded from the main
numbers.

For NeMo ASR, treat warm-up as model/runtime warm-up only. There is no
LLM-style prompt/KV cache to preserve across transcription requests, so the
one-off harness can warm STT with the same WAV and record the transcript and
duration as `stt_warmup_complete`. If a future run needs to avoid any repeated
input at all, add a second short WAV and use it only for warm-up.

For llama.cpp, send a simple prompt and record `llm_warmup_complete` so the
tester can verify the server can generate before cache behavior is measured.

For Pocket TTS, synthesize a simple `hello` and record
`tts_warmup_complete` with wall time, model generation time, output audio
duration, and realtime factor.

### 2. ASR-Only Baseline

Replay the WAV through the NeMo ASR websocket.

Record:

- Audio duration.
- Wall-clock transcription duration.
- Realtime factor, `asr_wall_seconds / audio_seconds`.
- Time from audio start to first transcript event.
- Time and text for each transcript chunk.
- Time and text for the completed ASR turn.
- Final transcript.

Treat the first realtime `completed` transcript as the assistant turn
transcript. Do not merge later segments to make the sample transcript match the
expected text. If server VAD cuts a user utterance too early, that is an ASR
turn-detection failure to record, not a condition the harness should repair.
Compare the realtime transcript against the HTTP STT warm-up transcript and
record the match result.
If no realtime transcript arrives after the silence tail, commit, and a short
completion grace window, fall back to HTTP transcription and mark
audio-end-relative metrics invalid.

### 3. LLM Cold Baseline

Send the final transcript prompt to the dedicated cold-baseline slot with no
prior cache warm in that slot.

Record:

- Prompt token count if available.
- Request start time.
- First generated token time.
- Cold TTFT.
- Decode tokens per second for a small fixed output budget.

Keep the output short. The model response quality is not the benchmark.

### 4. TTS Baseline

Send one fixed short assistant response to Pocket TTS.

Record:

- TTS model ID.
- Text character count.
- Time from request start to first audio bytes, if streaming exists.
- Time from request start to completed WAV.
- Output audio duration.
- TTS realtime factor, `tts_wall_seconds / output_audio_seconds`.

If the first implementation returns only a complete WAV, first-audio timing can
be omitted. Completed-WAV timing is sufficient for this one-off test.

### 5. LLM Cached Baseline

Replay the transcript chunks without audio.

For each stable chunk:

- Append the chunk to the canonical prompt buffer.
- Send the full current prompt to the cached-baseline slot.
- Enable prompt caching.
- Use zero-token cache warm if supported, otherwise one generated token and
  discard it.

After the final chunk:

- Send the final prompt to the same cached-baseline slot.
- Stream output.
- Record cached TTFT and decode tokens per second.

This isolates LLM cache behavior from ASR behavior.
The cold/cached comparison is only valid if cold and cached phases use separate
slots and the prompt contains a per-run id so state from earlier runs cannot be
reused.

### 6. Full Pipeline

Replay the WAV through NeMo ASR.

As stable transcript chunks arrive:

- Append each chunk to the canonical prompt buffer.
- Send cache warm requests to the same LLM slot.
- Do not wait for a model answer unless the cache warm request itself is still
  in flight.

At end of speech or end of WAV:

- Send the final prompt to the same slot.
- Stream the first response tokens.
- Accumulate the full short chat response.
- Send the final chat response to Pocket TTS.
- Save the spoken response WAV.
- Record end-to-end final TTFT from final transcript availability and from audio
  end.
- Record final spoken-response latency from final transcript availability and
  from audio end.

Audio-end latency fields are only valid for realtime ASR. If the client falls
back to HTTP transcription, retain final-text-relative timings but mark
audio-end-relative fields as invalid or `null`.

Only count the full-pipeline cache warm as incremental if the ASR websocket
emitted transcript deltas while the audio was streaming. If ASR only returns a
completed transcript, or if the client falls back to HTTP
transcription, record that no incremental full-pipeline cache warm happened
instead of issuing a posthoc warm request.

## Prompt Shape

Use a stable ChatML-style prefix so prompt-cache reuse is easy to verify and the
model is less likely to continue the prompt text into the spoken response:

```text
<|im_start|>system
You are a concise local voice assistant.
Reply directly to the user's transcribed speech in one or two short spoken sentences.
Do not expose hidden reasoning or implementation details.
Session id: {run_id}.
<|im_end|>
<|im_start|>user
{transcript_so_far}
/no_think
<|im_end|>
<|im_start|>assistant
<think>

</think>
```

The final LLM response should be normal chat text. Do not simulate MCP calls in
this benchmark. Future assistant behavior may speak a brief status/result even
when the real work is an MCP call, but this run only needs the chat-to-speech
path.

Use greedy decoding and a small token cap. The prompt includes `/no_think` and
an empty Qwen assistant prefill so Qwen-style thinking models do not spend the
measured decode budget on reasoning tokens. The client may trim only that exact
adapter prefix and protocol sentinel tokens if the server returns them in the
completion text. Do not remove generated reasoning text, role-like text, or bad
answers after the fact, and do not replace an empty or bad response with a
hard-coded success string. Save the raw LLM completion next to the spoken text.

## Metrics

Write one JSONL event per meaningful step:

```json
{"event":"stt_warmup_complete","t_ms":800,"wall_ms":610,"transcript_chars":120}
{"event":"llm_warmup_complete","t_ms":1100,"wall_ms":280,"ttft_ms":190,"text":"OK"}
{"event":"tts_warmup_complete","t_ms":1800,"generation_ms":500,"audio_seconds":0.7}
{"event":"asr_completed_segment","t_ms":2400,"text":"turn on the office light"}
{"event":"asr_reference_check","t_ms":2500,"label":"baseline","matches":true}
{"event":"asr_chunk","t_ms":1234,"text":"turn on the"}
{"event":"llm_cache_warm","t_ms":1402,"slot":0,"prompt_chars":812,"latency_ms":95}
{"event":"llm_final_first_token","t_ms":3100,"slot":0,"ttft_ms":180}
{"event":"tts_input_first_sentence_ready","t_ms":3300,"text_chars":54}
{"event":"tts_stream_first_audio_chunk","t_ms":3500,"latency_ms":190}
{"event":"llm_response_raw","t_ms":3200,"text":"...","text_chars":42}
{"event":"llm_response_protocol_trimmed","t_ms":3201,"trimmed":["qwen_assistant_prefill"]}
{"event":"tts_stream_response_complete","t_ms":5200,"segments":2,"audio_seconds":4.2}
```

Final summary fields:

```json
{
  "audio_seconds": 0.0,
  "asr_wall_seconds": 0.0,
  "asr_realtime_factor": 0.0,
  "asr_matches_stt_warmup": true,
  "asr_first_chunk_ms": 0,
  "chunk_count": 0,
  "cache_warm_count": 0,
  "cache_warm_p50_ms": 0,
  "cache_warm_p95_ms": 0,
  "llm_slot_strategy": "separate_slots_with_run_id",
  "llm_slot_assignments": {},
  "full_pipeline_first_audio_chunk_from_audio_end_ms": 0,
  "full_pipeline_tts_generation_done_from_audio_end_ms": 0,
  "full_pipeline_playback_complete_from_audio_end_ms": 0,
  "tts_stream_segment_count": 2,
  "tts_input_first_segment_text_ratio": 0.0,
  "tts_input_first_segment_audio_ratio": 0.0,
  "tts_input_first_segment_generation_ratio": 0.0,
  "llm_cache_comparison_valid": true,
  "full_pipeline_llm_cache_valid": true,
  "full_pipeline_chunk_source": "",
  "full_pipeline_asr_mode": "",
  "full_pipeline_asr_wall_seconds": 0.0,
  "full_pipeline_asr_matches_stt_warmup": true,
  "full_pipeline_cache_warm_timing": "",
  "full_pipeline_cache_warm_count": 0,
  "full_pipeline_cache_warm_p50_ms": 0,
  "full_pipeline_cache_warm_p95_ms": 0,
  "cold_final_ttft_ms": 0,
  "cached_final_ttft_ms": 0,
  "cold_final_ttft_ms_raw": 0,
  "cached_final_ttft_ms_raw": 0,
  "full_pipeline_audio_end_reference_valid": true,
  "full_pipeline_final_ttft_from_audio_end_ms": 0,
  "full_pipeline_final_ttft_from_final_text_ms": 0,
  "full_pipeline_response_text": "",
  "full_pipeline_response_raw": "",
  "decode_tokens_per_second": 0.0,
  "tts_wall_seconds": 0.0,
  "tts_generation_seconds": 0.0,
  "tts_output_audio_seconds": 0.0,
  "tts_streaming_enabled": true,
  "tts_stream_segment_count": 0,
  "tts_first_audio_chunk_ms": 0,
  "tts_stream_playback_seconds": 0.0,
  "tts_stream_playback_gap_seconds": 0.0,
  "tts_stream_wall_realtime_factor": 0.0,
  "tts_input_first_sentence_ready_from_llm_request_ms": 0,
  "tts_input_first_sentence_to_first_audio_ms": 0,
  "tts_input_first_segment_text_ratio": 0.0,
  "tts_input_tail_text_ratio": 0.0,
  "tts_input_first_segment_audio_ratio": 0.0,
  "tts_input_tail_audio_ratio": 0.0,
  "tts_input_first_segment_generation_ratio": 0.0,
  "tts_input_tail_generation_ratio": 0.0,
  "tts_realtime_factor": 0.0,
  "stt_warmup_wall_seconds": 0.0,
  "stt_warmup_transcript": "",
  "llm_warmup_ttft_ms": 0,
  "tts_warmup_wall_seconds": 0.0,
  "tts_warmup_generation_seconds": 0.0,
  "tts_warmup_audio_seconds": 0.0,
  "tts_warmup_realtime_factor": 0.0,
  "full_pipeline_spoken_response_from_audio_end_ms": 0,
  "full_pipeline_spoken_response_from_final_text_ms": 0,
  "asr_model": "",
  "asr_backend": "",
  "asr_stream_strategy": "",
  "asr_stream_sample_rate": 16000,
  "asr_trailing_silence_ms": 0,
  "asr_completion_grace_ms": 0,
  "llm_model": "",
  "tts_model": "",
  "asr_backend_image": "",
  "llama_server_image": "",
  "tts_backend_image": "",
  "notes": []
}
```

Primary pass/fail signal:

```text
cached_final_ttft_ms < cold_final_ttft_ms
```

Secondary useful signals:

- ASR realtime factor close to or below `1.0`.
- Cache warm p95 does not grow linearly with the whole accumulated transcript.
- Full-pipeline final TTFT is close to the cached LLM-only final TTFT.
- Pocket TTS completes a short response without exhausting node CPU or
  memory, even if CPU synthesis is slower than realtime.

## Resource Policy

Do not set pod CPU or memory requests/limits for this temporary benchmark. On
the single-node cluster, fixed pod resources create artificial scheduling
failures and can distort CPU behavior without making the measurement more
representative. Let the node admit the benchmark pods and observe actual runtime
behavior from the benchmark metrics and pod logs.

If CPU contention hides the LLM cache effect, run TTS strictly after the LLM
response is complete. The first benchmark should prioritize clear stage timing
over simultaneous load.

## Storage

Use PVCs on `zfs-bulk` so model downloads can be reused across small reruns:

- `nemo-asr-cache`
- `llama-cache`
- `chatterbox-cache` for the TTS service. This retained name is historical;
  the current backend is Pocket TTS.

Use `emptyDir` for the first attempt if faster to write. Either choice is fine
as long as cleanup remains trivial.

These PVCs are still benchmark resources, not platform state. Delete them
manually when the test work is done.

## Rerun Knobs

The likely rerun changes are:

- WAV file.
- ASR model: FastConformer streaming first; Parakeet next if useful.
- ASR partial strategy: NeMo cache-aware `conformer_stream_step` over
  continuous websocket input features.
- LLM model: Qwen3-1.7B, Qwen3-4B, another 1-4B instruct model.
- LLM quantization level.
- TTS model: Pocket TTS first; optionally another smaller/faster TTS fallback if
  CPU synthesis is still unusably slow.
- TTS execution mode: separate service, or in-process inside the client Job.
- Audio chunk size.
- Transcript stabilization policy.
- Cache warm mode: zero-token if supported, one-token discard otherwise.
- CPU thread counts.
- GPU image and accelerator-specific scheduling, if GPU support is added later.

Each run should write a new result file with the parameter values included.

## Expected Artifacts

For a later implementation, keep generated outputs outside the long-lived
platform layout. A simple local directory such as this is enough:

```text
tmp/ai-perf-test/
  run-YYYYMMDD-HHMMSS/
    manifest.yaml
    events.jsonl
    summary.json
    transcript.txt
    response.txt
    response.wav
```

Do not add generated run outputs to Git.

## Success Criteria

The test is complete when it provides:

- A final transcript for the WAV.
- ASR realtime factor.
- Cold final LLM TTFT.
- Cached final LLM TTFT.
- Full-pipeline final TTFT.
- Pocket TTS first-audio latency, generation time, output audio duration,
  playback completion time, and realtime factor.
- TTS input split ratios for first sentence vs tail text, audio duration, and
  generation time.
- A generated spoken response WAV for the chat answer.
- The model IDs, image tags, scheduling settings, and cache warm mode used.
- A short note explaining whether the cache-warmed path demonstrated the
  expected TTFT reduction.

If the cached path does not improve TTFT, that is still a useful result. In that
case, inspect slot assignment, prompt identity, and whether the cache warm
request actually populates the server-side cache before changing hardware or
models.
