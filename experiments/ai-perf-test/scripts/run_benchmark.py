import asyncio
import base64
import json
import math
import os
import re
import statistics
import threading
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse, urlunparse

import audioop
import httpx
import websockets

RUN_ID = datetime.now(UTC).strftime('%Y%m%d-%H%M%S')
RESULTS_ROOT = Path(os.getenv('RESULTS_DIR', '/results'))
RUN_DIR = RESULTS_ROOT / f'run-{RUN_ID}'
RUN_DIR.mkdir(parents=True, exist_ok=True)

EVENTS_PATH = RUN_DIR / 'events.jsonl'
SUMMARY_PATH = RUN_DIR / 'summary.json'
TRANSCRIPT_PATH = RUN_DIR / 'transcript.txt'
RESPONSE_PATH = RUN_DIR / 'response.txt'
RESPONSE_RAW_PATH = RUN_DIR / 'response-raw.txt'
RESPONSE_WAV_PATH = RUN_DIR / 'response.wav'
START = time.perf_counter()
EVENTS = EVENTS_PATH.open('a', encoding='utf-8')
EVENT_LOCK = threading.Lock()
NOTES: list[str] = []
LAST_ASR_CHUNK_SOURCE: str | None = None
LAST_ASR_FIRST_CHUNK_MS: int | None = None
LAST_ASR_STREAM_STRATEGY: str | None = None


def env(name: str, default: str) -> str:
    return os.getenv(name, default)


ASR_BASE_URL = env('ASR_BASE_URL', 'http://nemo-asr:8002').rstrip('/')
ASR_WS_URL = env('ASR_WS_URL', '')
ASR_BACKEND_NAME = env('ASR_BACKEND_NAME', 'nemo-asr')
ASR_STREAM_SAMPLE_RATE = int(env('ASR_STREAM_SAMPLE_RATE', '16000'))
LLAMA_BASE_URL = env('LLAMA_BASE_URL', 'http://llama-server:8080').rstrip('/')
TTS_BASE_URL = env('TTS_BASE_URL', 'http://chatterbox-tts:8001').rstrip('/')
ASR_MODEL = env('ASR_MODEL', 'nvidia/stt_en_fastconformer_hybrid_large_streaming_multi')
LLM_MODEL = env('LLM_MODEL', 'qwen3-1.7b')
TTS_MODEL = env('TTS_MODEL', 'kyutai/pocket-tts')
INPUT_WAV = Path(env('INPUT_WAV', '/input/input.wav'))
CHUNK_MS = int(env('CHUNK_MS', '250'))
ASR_TRAILING_SILENCE_MS = int(env('ASR_TRAILING_SILENCE_MS', '500'))
ASR_COMPLETION_GRACE_MS = int(env('ASR_COMPLETION_GRACE_MS', '5000'))
LLM_WARMUP_SLOT = int(env('LLM_WARMUP_SLOT', '0'))
LLM_COLD_SLOT = int(env('LLM_COLD_SLOT', '1'))
LLM_CACHED_SLOT = int(env('LLM_CACHED_SLOT', '2'))
LLM_FULL_SLOT = int(env('LLM_FULL_SLOT', '3'))
LLM_MAX_TOKENS = int(env('LLM_MAX_TOKENS', '16'))
CACHE_WARM_TOKENS = int(env('CACHE_WARM_TOKENS', '0'))
CACHE_WARM_FALLBACK_TOKENS = int(env('CACHE_WARM_FALLBACK_TOKENS', '1'))
REQUEST_TIMEOUT = float(env('REQUEST_TIMEOUT_SECONDS', '3600'))
LLM_SLOT_ASSIGNMENTS = {
    'warmup': LLM_WARMUP_SLOT,
    'cold_baseline': LLM_COLD_SLOT,
    'cached_baseline': LLM_CACHED_SLOT,
    'full_pipeline': LLM_FULL_SLOT,
}
QWEN_ASSISTANT_PREFILL = '<think>\n\n</think>\n'


def elapsed_ms() -> int:
    return int((time.perf_counter() - START) * 1000)


def event(name: str, **fields: Any) -> None:
    payload = {'event': name, 't_ms': elapsed_ms(), **fields}
    line = json.dumps(payload, sort_keys=True)
    with EVENT_LOCK:
        EVENTS.write(line + '\n')
        EVENTS.flush()
        print(line, flush=True)


def note(message: str) -> None:
    NOTES.append(message)
    event('note', message=message)


def require_input_wav() -> None:
    if INPUT_WAV.exists():
        return
    raise SystemExit(
        f'Missing {INPUT_WAV}. Create ConfigMap ai-perf-input with key input.wav '
        'before running the Job. See experiments/ai-perf-test/README.md.',
    )


def wav_info(path: Path) -> dict[str, Any]:
    with wave.open(str(path), 'rb') as wav:
        frames = wav.getnframes()
        rate = wav.getframerate()
        return {
            'frames': frames,
            'sample_rate': rate,
            'channels': wav.getnchannels(),
            'sample_width': wav.getsampwidth(),
            'duration_seconds': frames / float(rate),
        }


def wait_http_ready(
    name: str,
    url: str,
    required_json: dict[str, Any] | None = None,
) -> None:
    deadline = time.monotonic() + REQUEST_TIMEOUT
    health_url = f'{url}/health'
    while True:
        try:
            response = httpx.get(health_url, timeout=10.0)
            if response.status_code == 200:
                if required_json:
                    try:
                        body = response.json()
                    except ValueError:
                        event(
                            'service_not_ready',
                            service=name,
                            reason='health_not_json',
                            body=response.text[:300],
                        )
                    else:
                        missing = {
                            key: value
                            for key, value in required_json.items()
                            if body.get(key) != value
                        }
                        if not missing:
                            event('service_ready', service=name, url=health_url)
                            return
                        event(
                            'service_not_ready',
                            service=name,
                            reason='missing_health_capability',
                            required=missing,
                            body=body,
                        )
                else:
                    event('service_ready', service=name, url=health_url)
                    return
            else:
                event('service_not_ready', service=name, status=response.status_code)
        except Exception as exc:
            event('service_wait_error', service=name, error=repr(exc))
        if time.monotonic() > deadline:
            raise TimeoutError(f'{name} did not become ready at {health_url}')
        time.sleep(10)


def ensure_asr_model() -> None:
    started = time.perf_counter()
    response = httpx.post(
        f'{ASR_BASE_URL}/v1/models/{quote(ASR_MODEL, safe="")}',
        timeout=REQUEST_TIMEOUT,
    )
    if response.status_code not in (200, 201):
        event(
            'asr_model_download_failed',
            model=ASR_MODEL,
            status=response.status_code,
            body=response.text[:1000],
        )
        response.raise_for_status()
    event(
        'asr_model_ready',
        backend=ASR_BACKEND_NAME,
        model=ASR_MODEL,
        status=response.status_code,
        latency_ms=int((time.perf_counter() - started) * 1000),
        body=response.text[:300],
    )


def websocket_url() -> str:
    if ASR_WS_URL:
        return ASR_WS_URL
    parsed = urlparse(ASR_BASE_URL)
    scheme = 'wss' if parsed.scheme == 'https' else 'ws'
    query = f'model={quote(ASR_MODEL)}&language=en'
    return urlunparse((scheme, parsed.netloc, '/v1/realtime', '', query, ''))


def split_text_chunks(text: str, words_per_chunk: int = 8) -> list[str]:
    words = text.split()
    if not words:
        return []
    return [' '.join(words[i : i + words_per_chunk]) for i in range(0, len(words), words_per_chunk)]


def normalize_text(text: str) -> str:
    return ' '.join(text.casefold().split())


async def transcribe_http(
    on_chunk=None,
    *,
    label: str = 'http_fallback',
    emit_chunks: bool = True,
) -> tuple[str, list[str], float, str]:
    global LAST_ASR_CHUNK_SOURCE
    started = time.perf_counter()
    with INPUT_WAV.open('rb') as audio:
        response = httpx.post(
            f'{ASR_BASE_URL}/v1/audio/transcriptions',
            data={'model': ASR_MODEL},
            files={'file': ('input.wav', audio, 'audio/wav')},
            timeout=REQUEST_TIMEOUT,
        )
    response.raise_for_status()
    try:
        data = response.json()
        transcript = data.get('text') or data.get('transcript') or json.dumps(data)
    except ValueError:
        transcript = response.text
    chunks = split_text_chunks(transcript)
    LAST_ASR_CHUNK_SOURCE = 'http_split'
    for chunk in chunks:
        if emit_chunks:
            event('asr_chunk', mode=label, text=chunk)
        if on_chunk is not None:
            await on_chunk(chunk)
    return transcript, chunks, time.perf_counter() - started, label


async def warm_up_stt() -> dict[str, Any]:
    transcript, chunks, wall, mode = await transcribe_http(
        label='warmup',
        emit_chunks=False,
    )
    event(
        'stt_warmup_complete',
        mode=mode,
        wall_ms=int(wall * 1000),
        chunks=len(chunks),
        transcript_chars=len(transcript),
        transcript=transcript[:300],
    )
    return {
        'mode': mode,
        'wall_seconds': wall,
        'chunks': len(chunks),
        'transcript': transcript,
    }


async def transcribe_realtime(
    on_chunk=None,
    *,
    posthoc_on_chunk: bool = True,
) -> tuple[str, list[str], float, str]:
    global LAST_ASR_CHUNK_SOURCE, LAST_ASR_FIRST_CHUNK_MS, LAST_ASR_STREAM_STRATEGY
    LAST_ASR_CHUNK_SOURCE = None
    LAST_ASR_FIRST_CHUNK_MS = None
    LAST_ASR_STREAM_STRATEGY = None
    info = wav_info(INPUT_WAV)
    if info['sample_width'] != 2:
        note(
            'Realtime ASR requires PCM16 WAV for this harness; falling back to HTTP transcription.',
        )
        return await transcribe_http(on_chunk=on_chunk if posthoc_on_chunk else None)

    url = websocket_url()
    chunks: list[str] = []
    deltas: list[str] = []
    completed_transcript: str | None = None
    done = asyncio.Event()
    started = time.perf_counter()

    try:
        async with websockets.connect(url, open_timeout=30, close_timeout=10) as ws:
            await ws.send(
                json.dumps(
                    {
                        'type': 'session.update',
                        'session': {
                            'input_audio_format': 'pcm16',
                            'input_audio_sample_rate': ASR_STREAM_SAMPLE_RATE,
                            'input_audio_channels': 1,
                            'input_audio_transcription': {
                                'model': ASR_MODEL,
                                'language': 'en',
                            },
                            'turn_detection': {
                                'type': 'server_vad',
                                'create_response': False,
                            },
                        },
                    },
                ),
            )

            async def receive() -> None:
                global LAST_ASR_CHUNK_SOURCE, LAST_ASR_FIRST_CHUNK_MS, LAST_ASR_STREAM_STRATEGY
                nonlocal completed_transcript
                async for raw in ws:
                    try:
                        data = json.loads(raw)
                    except ValueError:
                        event('asr_raw_message', data=str(raw)[:500])
                        continue
                    msg_type = str(data.get('type', ''))
                    if msg_type == 'error':
                        event('asr_error', mode='realtime', data=data)
                        done.set()
                        return
                    if 'transcription' not in msg_type and 'transcript' not in data:
                        continue
                    source = str(data.get('source') or 'realtime_delta')
                    LAST_ASR_STREAM_STRATEGY = source

                    delta = data.get('delta') or data.get('transcript_delta')
                    if isinstance(delta, str) and delta:
                        deltas.append(delta)
                        chunks.append(delta)
                        LAST_ASR_CHUNK_SOURCE = source
                        if LAST_ASR_FIRST_CHUNK_MS is None:
                            LAST_ASR_FIRST_CHUNK_MS = int(
                                (time.perf_counter() - started) * 1000,
                            )
                        event(
                            'asr_chunk',
                            mode='realtime',
                            source=source,
                            message_type=msg_type,
                            text=delta,
                        )
                        if on_chunk is not None:
                            await on_chunk(delta)

                    transcript = data.get('transcript')
                    if isinstance(transcript, str) and transcript:
                        completed_transcript = transcript
                        event(
                            'asr_transcript',
                            mode='realtime',
                            source=source,
                            message_type=msg_type,
                            text=transcript,
                        )
                        if 'completed' in msg_type:
                            event(
                                'asr_completed_segment',
                                mode='realtime',
                                source=source,
                                text=transcript,
                            )
                            done.set()
                            return

            receiver = asyncio.create_task(receive())
            frames_per_chunk = max(1, int(info['sample_rate'] * CHUNK_MS / 1000))
            resample_state = None
            with wave.open(str(INPUT_WAV), 'rb') as wav:
                while True:
                    if done.is_set():
                        break
                    frames = wav.readframes(frames_per_chunk)
                    if not frames:
                        break
                    source_frame_count = len(frames) // info['sample_width'] // info['channels']
                    if info['channels'] != 1:
                        frames = audioop.tomono(frames, info['sample_width'], 0.5, 0.5)
                    if info['sample_rate'] != ASR_STREAM_SAMPLE_RATE:
                        frames, resample_state = audioop.ratecv(
                            frames,
                            info['sample_width'],
                            1,
                            info['sample_rate'],
                            ASR_STREAM_SAMPLE_RATE,
                            resample_state,
                        )
                    await ws.send(
                        json.dumps(
                            {
                                'type': 'input_audio_buffer.append',
                                'audio': base64.b64encode(frames).decode('ascii'),
                            },
                        ),
                    )
                    event('audio_chunk_sent', frames=source_frame_count)
                    await asyncio.sleep(source_frame_count / info['sample_rate'])

            if not done.is_set():
                event('audio_replay_complete', trailing_silence_ms=ASR_TRAILING_SILENCE_MS)
            remaining_silence_ms = ASR_TRAILING_SILENCE_MS
            while not done.is_set() and remaining_silence_ms > 0:
                chunk_ms = min(CHUNK_MS, remaining_silence_ms)
                silence_frames = max(1, int(ASR_STREAM_SAMPLE_RATE * chunk_ms / 1000))
                await ws.send(
                    json.dumps(
                        {
                            'type': 'input_audio_buffer.append',
                            'audio': base64.b64encode(b'\x00\x00' * silence_frames).decode(
                                'ascii',
                            ),
                        },
                    ),
                )
                event(
                    'audio_trailing_silence_sent',
                    duration_ms=chunk_ms,
                    sample_rate=ASR_STREAM_SAMPLE_RATE,
                    frames=silence_frames,
                )
                await asyncio.sleep(chunk_ms / 1000)
                remaining_silence_ms -= chunk_ms

            if not done.is_set():
                await ws.send(json.dumps({'type': 'input_audio_buffer.commit'}))

            if not done.is_set():
                try:
                    await asyncio.wait_for(done.wait(), timeout=ASR_COMPLETION_GRACE_MS / 1000)
                except TimeoutError:
                    note(
                        'Timed out waiting for realtime ASR completion after trailing silence; '
                        'using collected transcript data.',
                    )
            receiver.cancel()
            try:
                await receiver
            except asyncio.CancelledError:
                pass
    except Exception as exc:
        note(f'Realtime ASR failed with {exc!r}; falling back to HTTP transcription.')
        return await transcribe_http(on_chunk=on_chunk if posthoc_on_chunk else None)

    transcript = completed_transcript or ''.join(deltas).strip()
    if not transcript:
        note('Realtime ASR produced no transcript; falling back to HTTP transcription.')
        return await transcribe_http(on_chunk=on_chunk if posthoc_on_chunk else None)
    if not chunks:
        chunks = split_text_chunks(transcript)
        LAST_ASR_CHUNK_SOURCE = 'completed_transcript_split'
        event(
            'asr_chunks_derived',
            mode='realtime',
            source=LAST_ASR_CHUNK_SOURCE,
            chunks=len(chunks),
        )
        if posthoc_on_chunk and on_chunk is not None:
            for chunk in chunks:
                await on_chunk(chunk)
    return transcript, chunks, time.perf_counter() - started, 'realtime'


def build_prompt(transcript: str, final: bool) -> str:
    return f"""<|im_start|>system
You are a concise local voice assistant.
Reply directly to the user's transcribed speech in one or two short spoken sentences.
Do not expose hidden reasoning or implementation details.
Session id: {RUN_ID}.
<|im_end|>
<|im_start|>user
{transcript.strip()}
/no_think
<|im_end|>
<|im_start|>assistant
{QWEN_ASSISTANT_PREFILL}
"""


def strip_spoken_protocol(text: str) -> tuple[str, list[str]]:
    cleaned = text
    trimmed: list[str] = []
    if cleaned.startswith(QWEN_ASSISTANT_PREFILL):
        cleaned = cleaned[len(QWEN_ASSISTANT_PREFILL) :]
        trimmed.append('qwen_assistant_prefill')
    for marker in ('<|im_end|>', '<|im_start|>', '<|endoftext|>', '</s>'):
        if marker in cleaned:
            cleaned = cleaned.replace(marker, '')
            trimmed.append(marker)
    cleaned = cleaned.strip()
    return cleaned, trimmed


def clean_spoken_response(text: str) -> str:
    cleaned, trimmed = strip_spoken_protocol(text)
    if trimmed:
        event(
            'llm_response_protocol_trimmed',
            raw=text[:500],
            cleaned=cleaned[:500],
            trimmed=trimmed,
        )
    return cleaned


def first_sentence_prefix(text: str) -> str | None:
    cleaned = text.strip()
    if not cleaned:
        return None
    for match in re.finditer(r'[.!?](?=\s|$)', cleaned):
        sentence = cleaned[: match.end()].strip()
        if sentence:
            return sentence
    return None


def trim_remainder(response_text: str, first_segment: str) -> str:
    if response_text.startswith(first_segment):
        return response_text[len(first_segment) :].strip()
    # Avoid trying to realign semantically. If punctuation/protocol trimming made
    # the prefix ambiguous, keep the already spoken first segment and skip a tail
    # rather than synthesize duplicated or invented text.
    note('Could not align streamed first sentence with final response text; skipping tail TTS.')
    return ''


def validate_llm_slot_plan() -> None:
    slots = list(LLM_SLOT_ASSIGNMENTS.values())
    if len(set(slots)) != len(slots):
        raise SystemExit(f'LLM slots must be distinct for this benchmark: {LLM_SLOT_ASSIGNMENTS}')
    event('llm_slot_plan', strategy='separate_slots_with_run_id', slots=LLM_SLOT_ASSIGNMENTS)


def parse_sse_json(line: str) -> dict[str, Any] | None:
    line = line.strip()
    if not line:
        return None
    if line.startswith('data:'):
        line = line[5:].strip()
    if line == '[DONE]':
        return None
    try:
        return json.loads(line)
    except ValueError:
        return None


def llama_completion(
    prompt: str,
    n_predict: int,
    stream: bool,
    label: str,
    slot: int,
) -> dict[str, Any]:
    payload = {
        'prompt': prompt,
        'n_predict': n_predict,
        'id_slot': slot,
        'cache_prompt': True,
        'temperature': 0.0,
        'top_p': 1.0,
        'stream': stream,
        'timings_per_token': True,
        'stop': ['<|im_end|>', '<|im_start|>', '<|endoftext|>', '</s>'],
        'repeat_penalty': 1.1,
    }
    started = time.perf_counter()
    first_token_at: float | None = None
    content_parts: list[str] = []
    final_json: dict[str, Any] = {}

    if stream:
        with httpx.stream(
            'POST',
            f'{LLAMA_BASE_URL}/completion',
            json=payload,
            timeout=REQUEST_TIMEOUT,
        ) as response:
            response.raise_for_status()
            for line in response.iter_lines():
                data = parse_sse_json(line)
                if not data:
                    continue
                final_json = data
                token = data.get('content')
                if isinstance(token, str) and token:
                    if first_token_at is None:
                        first_token_at = time.perf_counter()
                        event(
                            'llm_final_first_token',
                            label=label,
                            slot=slot,
                            ttft_ms=int((first_token_at - started) * 1000),
                        )
                    content_parts.append(token)
    else:
        response = httpx.post(
            f'{LLAMA_BASE_URL}/completion',
            json=payload,
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        final_json = response.json()
        token = final_json.get('content')
        if isinstance(token, str):
            content_parts.append(token)

    wall = time.perf_counter() - started
    timings = final_json.get('timings', {}) if isinstance(final_json, dict) else {}
    return {
        'text': ''.join(content_parts),
        'wall_seconds': wall,
        'ttft_ms': int((first_token_at - started) * 1000) if first_token_at else None,
        'predicted_per_second': timings.get('predicted_per_second'),
        'raw': final_json,
    }


def cache_warm(prompt: str, label: str, slot: int) -> float:
    started = time.perf_counter()
    try:
        llama_completion(prompt, CACHE_WARM_TOKENS, stream=False, label=label, slot=slot)
        latency = time.perf_counter() - started
        event(
            'llm_cache_warm',
            label=label,
            slot=slot,
            latency_ms=int(latency * 1000),
            tokens=CACHE_WARM_TOKENS,
        )
        return latency
    except Exception as exc:
        event(
            'llm_cache_warm_error',
            label=label,
            slot=slot,
            error=repr(exc),
            tokens=CACHE_WARM_TOKENS,
        )
        started = time.perf_counter()
        llama_completion(prompt, CACHE_WARM_FALLBACK_TOKENS, stream=False, label=label, slot=slot)
        latency = time.perf_counter() - started
        event(
            'llm_cache_warm',
            label=label,
            slot=slot,
            latency_ms=int(latency * 1000),
            tokens=CACHE_WARM_FALLBACK_TOKENS,
        )
        return latency


def warm_up_llama() -> dict[str, Any]:
    result = llama_completion(
        '<|im_start|>system\nReply with exactly OK and nothing else.\n<|im_end|>\n'
        f'<|im_start|>user\nWarm up.\n/no_think\n<|im_end|>\n<|im_start|>assistant\n{QWEN_ASSISTANT_PREFILL}',
        4,
        stream=True,
        label='warmup',
        slot=LLM_WARMUP_SLOT,
    )
    text = result['text'].strip()
    event(
        'llm_warmup_complete',
        text=text[:300],
        wall_ms=int(result['wall_seconds'] * 1000),
        ttft_ms=result['ttft_ms'],
        predicted_per_second=result['predicted_per_second'],
    )
    return result


def warm_up_tts() -> dict[str, Any]:
    result = synthesize('hello', 'warmup', RUN_DIR / 'tts-warmup.wav')
    event(
        'tts_warmup_complete',
        wall_ms=int(result['wall_seconds'] * 1000),
        generation_ms=int(result['generation_seconds'] * 1000),
        audio_seconds=result['audio_seconds'],
        realtime_factor=result['realtime_factor'],
    )
    return result


def pcm_audio_seconds(byte_count: int, sample_rate: int, sample_width: int, channels: int) -> float:
    bytes_per_frame = sample_width * channels
    if sample_rate <= 0 or bytes_per_frame <= 0:
        return 0.0
    return byte_count / float(sample_rate * bytes_per_frame)


def pcm_silence(seconds: float, sample_rate: int, sample_width: int, channels: int) -> bytes:
    frame_count = max(0, int(round(seconds * sample_rate)))
    return b'\x00' * frame_count * sample_width * channels


def write_pcm_wav(
    path: Path,
    pcm_parts: list[bytes],
    sample_rate: int,
    sample_width: int,
    channels: int,
) -> None:
    with wave.open(str(path), 'wb') as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(sample_width)
        wav.setframerate(sample_rate)
        for part in pcm_parts:
            wav.writeframes(part)


def synthesize(text: str, label: str, output_path: Path) -> dict[str, Any]:
    started = time.perf_counter()
    response = httpx.post(
        f'{TTS_BASE_URL}/synthesize',
        json={'text': text},
        timeout=REQUEST_TIMEOUT,
    )
    response.raise_for_status()
    output_path.write_bytes(response.content)
    wall = time.perf_counter() - started
    try:
        with wave.open(str(output_path), 'rb') as wav:
            audio_seconds = wav.getnframes() / float(wav.getframerate())
    except Exception:
        audio_seconds = float(response.headers.get('X-TTS-Audio-Seconds', '0') or 0)
    header_wall = float(response.headers.get('X-TTS-Wall-Seconds', '0') or 0)
    tts_wall = header_wall or wall
    event(
        'tts_complete',
        label=label,
        text_chars=len(text),
        latency_ms=int(wall * 1000),
        generation_ms=int(tts_wall * 1000),
        audio_seconds=audio_seconds,
    )
    return {
        'wall_seconds': wall,
        'generation_seconds': tts_wall,
        'audio_seconds': audio_seconds,
        'realtime_factor': tts_wall / audio_seconds if audio_seconds > 0 else None,
    }


def synthesize_stream(text: str, label: str) -> dict[str, Any]:
    started = time.perf_counter()
    first_chunk_at: float | None = None
    pcm_parts: list[bytes] = []
    sample_rate = 24000
    sample_width = 2
    channels = 1

    with httpx.stream(
        'POST',
        f'{TTS_BASE_URL}/synthesize_stream',
        json={'text': text},
        timeout=REQUEST_TIMEOUT,
    ) as response:
        response.raise_for_status()
        sample_rate = int(response.headers.get('X-TTS-Sample-Rate', sample_rate))
        sample_width = int(response.headers.get('X-TTS-Sample-Width', sample_width))
        channels = int(response.headers.get('X-TTS-Channels', channels))
        for chunk in response.iter_bytes():
            if not chunk:
                continue
            now = time.perf_counter()
            if first_chunk_at is None:
                first_chunk_at = now
                event(
                    'tts_stream_first_audio_chunk',
                    label=label,
                    latency_ms=int((first_chunk_at - started) * 1000),
                    bytes=len(chunk),
                    chunk_audio_seconds=pcm_audio_seconds(
                        len(chunk),
                        sample_rate,
                        sample_width,
                        channels,
                    ),
                )
            pcm_parts.append(chunk)

    complete_at = time.perf_counter()
    pcm = b''.join(pcm_parts)
    audio_seconds = pcm_audio_seconds(len(pcm), sample_rate, sample_width, channels)
    generation_seconds = complete_at - started
    event(
        'tts_stream_complete',
        label=label,
        text_chars=len(text),
        latency_ms=int(generation_seconds * 1000),
        first_chunk_ms=(
            int((first_chunk_at - started) * 1000) if first_chunk_at is not None else None
        ),
        audio_seconds=audio_seconds,
        realtime_factor=generation_seconds / audio_seconds if audio_seconds > 0 else None,
    )
    return {
        'label': label,
        'text': text,
        'text_chars': len(text),
        'pcm': pcm,
        'sample_rate': sample_rate,
        'sample_width': sample_width,
        'channels': channels,
        'started_at': started,
        'first_chunk_at': first_chunk_at,
        'complete_at': complete_at,
        'first_chunk_ms': (
            int((first_chunk_at - started) * 1000) if first_chunk_at is not None else None
        ),
        'generation_seconds': generation_seconds,
        'audio_seconds': audio_seconds,
        'realtime_factor': generation_seconds / audio_seconds if audio_seconds > 0 else None,
    }


def streamed_llm_to_tts(
    prompt: str,
    n_predict: int,
    label: str,
    slot: int,
    output_path: Path,
) -> dict[str, Any]:
    payload = {
        'prompt': prompt,
        'n_predict': n_predict,
        'id_slot': slot,
        'cache_prompt': True,
        'temperature': 0.0,
        'top_p': 1.0,
        'stream': True,
        'timings_per_token': True,
        'stop': ['<|im_end|>', '<|im_start|>', '<|endoftext|>', '</s>'],
        'repeat_penalty': 1.1,
    }
    llm_started = time.perf_counter()
    first_token_at: float | None = None
    first_sentence_at: float | None = None
    first_sentence_text: str | None = None
    raw_parts: list[str] = []
    final_json: dict[str, Any] = {}

    with ThreadPoolExecutor(max_workers=1) as executor:
        first_future = None
        with httpx.stream(
            'POST',
            f'{LLAMA_BASE_URL}/completion',
            json=payload,
            timeout=REQUEST_TIMEOUT,
        ) as response:
            response.raise_for_status()
            for line in response.iter_lines():
                data = parse_sse_json(line)
                if not data:
                    continue
                final_json = data
                token = data.get('content')
                if not isinstance(token, str) or not token:
                    continue
                if first_token_at is None:
                    first_token_at = time.perf_counter()
                    event(
                        'llm_final_first_token',
                        label=label,
                        slot=slot,
                        ttft_ms=int((first_token_at - llm_started) * 1000),
                    )
                raw_parts.append(token)
                partial_text, _ = strip_spoken_protocol(''.join(raw_parts))
                if first_future is None:
                    candidate = first_sentence_prefix(partial_text)
                    if candidate is not None:
                        first_sentence_text = candidate
                        first_sentence_at = time.perf_counter()
                        event(
                            'tts_input_first_sentence_ready',
                            label=label,
                            text_chars=len(first_sentence_text),
                            from_llm_request_ms=int((first_sentence_at - llm_started) * 1000),
                            from_first_token_ms=(
                                int((first_sentence_at - first_token_at) * 1000)
                                if first_token_at is not None
                                else None
                            ),
                        )
                        first_future = executor.submit(
                            synthesize_stream,
                            first_sentence_text,
                            f'{label}-segment-0',
                        )

        llm_done_at = time.perf_counter()
        timings = final_json.get('timings', {}) if isinstance(final_json, dict) else {}
        response_raw = ''.join(raw_parts)
        response_text = clean_spoken_response(response_raw)
        if not response_text:
            raise RuntimeError('LLM produced an empty response')

        if first_future is None:
            first_sentence_text = response_text
            first_sentence_at = llm_done_at
            event(
                'tts_input_first_sentence_ready',
                label=label,
                source='llm_complete_no_sentence_boundary',
                text_chars=len(first_sentence_text),
                from_llm_request_ms=int((first_sentence_at - llm_started) * 1000),
                from_first_token_ms=(
                    int((first_sentence_at - first_token_at) * 1000)
                    if first_token_at is not None
                    else None
                ),
            )
            first_future = executor.submit(
                synthesize_stream,
                first_sentence_text,
                f'{label}-segment-0',
            )

        assert first_sentence_text is not None
        assert first_sentence_at is not None
        first_segment = first_future.result()
        segments = [first_segment]
        remainder = trim_remainder(response_text, first_sentence_text)
        if remainder:
            # Start the tail after the first segment has been generated. Pocket TTS
            # is faster than realtime, so this still models preparing the tail
            # while the first sentence is being played.
            tail_segment = synthesize_stream(remainder, f'{label}-segment-1')
            segments.append(tail_segment)

    sample_rate = int(segments[0]['sample_rate'])
    sample_width = int(segments[0]['sample_width'])
    channels = int(segments[0]['channels'])
    pcm_parts: list[bytes] = []
    playback_gaps: list[float] = []
    first_audio_at = segments[0]['first_chunk_at'] or segments[0]['complete_at']
    playback_cursor_at = first_audio_at
    for index, segment in enumerate(segments):
        if (
            int(segment['sample_rate']) != sample_rate
            or int(segment['sample_width']) != sample_width
            or int(segment['channels']) != channels
        ):
            raise RuntimeError('TTS stream segment audio format changed mid-response')

        segment_first_audio_at = segment['first_chunk_at'] or segment['complete_at']
        if index > 0:
            gap = max(0.0, segment_first_audio_at - playback_cursor_at)
            playback_gaps.append(gap)
            if gap > 0:
                event(
                    'tts_stream_playback_gap',
                    before_segment=index,
                    gap_ms=int(gap * 1000),
                )
                pcm_parts.append(pcm_silence(gap, sample_rate, sample_width, channels))
            segment_playback_start_at = max(playback_cursor_at, segment_first_audio_at)
        else:
            segment_playback_start_at = segment_first_audio_at
        pcm_parts.append(segment['pcm'])
        playback_cursor_at = segment_playback_start_at + segment['audio_seconds']

    write_pcm_wav(output_path, pcm_parts, sample_rate, sample_width, channels)
    generation_done_at = max(segment['complete_at'] for segment in segments)
    audio_seconds = sum(segment['audio_seconds'] for segment in segments)
    playback_gap_seconds = sum(playback_gaps)
    playback_seconds = audio_seconds + playback_gap_seconds
    text_chars = sum(segment['text_chars'] for segment in segments)
    stream_wall_seconds = generation_done_at - segments[0]['started_at']
    total_segment_generation_seconds = sum(
        segment['generation_seconds'] for segment in segments
    )
    first_segment_text_ratio = (
        segments[0]['text_chars'] / text_chars if text_chars > 0 else None
    )
    first_segment_audio_ratio = (
        segments[0]['audio_seconds'] / audio_seconds if audio_seconds > 0 else None
    )
    first_segment_generation_ratio = (
        segments[0]['generation_seconds'] / total_segment_generation_seconds
        if total_segment_generation_seconds > 0
        else None
    )
    event(
        'tts_stream_response_complete',
        label=label,
        segments=len(segments),
        text_chars=text_chars,
        audio_seconds=audio_seconds,
        playback_seconds=playback_seconds,
        playback_gap_ms=int(playback_gap_seconds * 1000),
        stream_wall_seconds=stream_wall_seconds,
        generation_seconds=total_segment_generation_seconds,
        first_segment_text_ratio=first_segment_text_ratio,
        first_segment_audio_ratio=first_segment_audio_ratio,
    )
    return {
        'text': response_text,
        'raw_text': response_raw,
        'wall_seconds': stream_wall_seconds,
        'generation_seconds': total_segment_generation_seconds,
        'audio_seconds': audio_seconds,
        'playback_seconds': playback_seconds,
        'playback_gap_seconds': playback_gap_seconds,
        'realtime_factor': (
            total_segment_generation_seconds / audio_seconds if audio_seconds > 0 else None
        ),
        'stream_wall_realtime_factor': (
            stream_wall_seconds / audio_seconds if audio_seconds > 0 else None
        ),
        'segments': segments,
        'segment_count': len(segments),
        'first_audio_at': first_audio_at,
        'playback_complete_at': playback_cursor_at,
        'generation_done_at': generation_done_at,
        'first_sentence_at': first_sentence_at,
        'llm_started_at': llm_started,
        'llm_done_at': llm_done_at,
        'first_token_at': first_token_at,
        'ttft_ms': int((first_token_at - llm_started) * 1000) if first_token_at else None,
        'predicted_per_second': timings.get('predicted_per_second'),
        'first_segment_text_ratio': first_segment_text_ratio,
        'first_segment_audio_ratio': first_segment_audio_ratio,
        'first_segment_generation_ratio': first_segment_generation_ratio,
        'tail_text_chars': sum(segment['text_chars'] for segment in segments[1:]),
        'tail_audio_seconds': sum(segment['audio_seconds'] for segment in segments[1:]),
        'tail_generation_seconds': sum(
            segment['generation_seconds'] for segment in segments[1:]
        ),
    }


async def main() -> None:
    require_input_wav()
    input_info = wav_info(INPUT_WAV)
    event('run_started', run_id=RUN_ID, input_wav=str(INPUT_WAV), wav_info=input_info)

    wait_http_ready('asr', ASR_BASE_URL, required_json={'streaming': True})
    wait_http_ready('llama-server', LLAMA_BASE_URL)
    wait_http_ready('tts', TTS_BASE_URL, required_json={'streaming': True})
    validate_llm_slot_plan()
    ensure_asr_model()
    stt_warmup = await warm_up_stt()
    llama_warmup = warm_up_llama()
    tts_warmup = warm_up_tts()

    transcript, chunks, asr_wall, asr_mode = await transcribe_realtime()
    asr_chunk_source = LAST_ASR_CHUNK_SOURCE
    asr_first_chunk_ms = LAST_ASR_FIRST_CHUNK_MS
    asr_stream_strategy = LAST_ASR_STREAM_STRATEGY
    TRANSCRIPT_PATH.write_text(transcript + '\n', encoding='utf-8')
    event(
        'asr_complete',
        mode=asr_mode,
        chunk_source=asr_chunk_source,
        wall_ms=int(asr_wall * 1000),
        chunks=len(chunks),
        transcript_chars=len(transcript),
    )
    asr_matches_reference = normalize_text(transcript) == normalize_text(stt_warmup['transcript'])
    event(
        'asr_reference_check',
        label='baseline',
        matches=asr_matches_reference,
        transcript_chars=len(transcript),
        reference_chars=len(stt_warmup['transcript']),
    )

    cold = llama_completion(
        build_prompt(transcript, final=True),
        LLM_MAX_TOKENS,
        stream=True,
        label='cold',
        slot=LLM_COLD_SLOT,
    )
    event(
        'llm_cold_complete',
        slot=LLM_COLD_SLOT,
        slot_isolated=True,
        wall_ms=int(cold['wall_seconds'] * 1000),
        ttft_ms=cold['ttft_ms'],
    )

    replay_transcript = ''
    cache_latencies: list[float] = []
    for chunk in chunks:
        replay_transcript = f'{replay_transcript} {chunk}'.strip()
        cache_latencies.append(
            cache_warm(
                build_prompt(replay_transcript, final=False),
                label='cached_baseline',
                slot=LLM_CACHED_SLOT,
            ),
        )
    cached = llama_completion(
        build_prompt(transcript, final=True),
        LLM_MAX_TOKENS,
        stream=True,
        label='cached',
        slot=LLM_CACHED_SLOT,
    )
    event(
        'llm_cached_complete',
        slot=LLM_CACHED_SLOT,
        slot_isolated=True,
        wall_ms=int(cached['wall_seconds'] * 1000),
        ttft_ms=cached['ttft_ms'],
    )

    full_transcript_parts: list[str] = []
    full_cache_latencies: list[float] = []

    async def full_on_chunk(chunk: str) -> None:
        full_transcript_parts.append(chunk)
        partial = ' '.join(full_transcript_parts)
        latency = await asyncio.to_thread(
            cache_warm,
            build_prompt(partial, final=False),
            'full_pipeline',
            LLM_FULL_SLOT,
        )
        full_cache_latencies.append(latency)

    full_started = time.perf_counter()
    full_transcript, full_chunks, full_asr_wall, full_asr_mode = await transcribe_realtime(
        on_chunk=full_on_chunk,
        posthoc_on_chunk=False,
    )
    full_chunk_source = LAST_ASR_CHUNK_SOURCE
    full_asr_first_chunk_ms = LAST_ASR_FIRST_CHUNK_MS
    full_asr_stream_strategy = LAST_ASR_STREAM_STRATEGY
    final_text_at = time.perf_counter()
    full_asr_matches_reference = normalize_text(full_transcript) == normalize_text(
        stt_warmup['transcript'],
    )
    event(
        'asr_reference_check',
        label='full_pipeline',
        matches=full_asr_matches_reference,
        transcript_chars=len(full_transcript),
        reference_chars=len(stt_warmup['transcript']),
    )
    if full_chunk_source not in (None, 'completed_transcript_split') and full_asr_mode == 'realtime':
        full_pipeline_cache_warm_timing = 'incremental_asr_delta'
    elif full_asr_mode == 'realtime':
        full_pipeline_cache_warm_timing = 'none_no_realtime_delta'
        event(
            'llm_cache_warm_skipped',
            label='full_pipeline',
            reason='no_realtime_delta',
            asr_mode=full_asr_mode,
            chunk_source=full_chunk_source,
        )
    else:
        full_pipeline_cache_warm_timing = 'none_http_fallback'
        event(
            'llm_cache_warm_skipped',
            label='full_pipeline',
            reason='http_fallback_not_incremental',
            asr_mode=full_asr_mode,
            chunk_source=full_chunk_source,
        )
    cache_warm_done_at = time.perf_counter()
    tts_final = streamed_llm_to_tts(
        build_prompt(full_transcript, final=True),
        LLM_MAX_TOKENS,
        label='full',
        slot=LLM_FULL_SLOT,
        output_path=RESPONSE_WAV_PATH,
    )
    first_token_at = tts_final['first_token_at']
    response_raw = tts_final['raw_text']
    RESPONSE_RAW_PATH.write_text(response_raw + '\n', encoding='utf-8')
    event('llm_response_raw', text=response_raw[:500], text_chars=len(response_raw))
    response_text = tts_final['text']
    event('llm_response_ready', text=response_text[:500], text_chars=len(response_text))
    RESPONSE_PATH.write_text(response_text + '\n', encoding='utf-8')
    first_audio_at = tts_final['first_audio_at']
    tts_generation_done_at = tts_final['generation_done_at']
    playback_done_at = tts_final['playback_complete_at']
    final_text_to_first_audio_ms = int((first_audio_at - final_text_at) * 1000)
    final_text_to_generation_done_ms = int((tts_generation_done_at - final_text_at) * 1000)
    final_text_to_playback_done_ms = int((playback_done_at - final_text_at) * 1000)
    audio_end_reference_valid = full_asr_mode == 'realtime'
    audio_end_at = (
        full_started + input_info['duration_seconds'] if audio_end_reference_valid else None
    )
    audio_end_to_first_audio_ms = (
        int((first_audio_at - audio_end_at) * 1000) if audio_end_at is not None else None
    )
    audio_end_to_generation_done_ms = (
        int((tts_generation_done_at - audio_end_at) * 1000) if audio_end_at is not None else None
    )
    audio_end_to_playback_done_ms = (
        int((playback_done_at - audio_end_at) * 1000) if audio_end_at is not None else None
    )
    full_pipeline_final_ttft_from_audio_end_ms_raw = (
        int((first_token_at - audio_end_at) * 1000)
        if first_token_at is not None and audio_end_at is not None
        else None
    )
    full_pipeline_final_ttft_from_final_text_ms_raw = (
        int((first_token_at - final_text_at) * 1000) if first_token_at is not None else None
    )
    event(
        'full_pipeline_complete',
        asr_mode=full_asr_mode,
        asr_wall_ms=int(full_asr_wall * 1000),
        chunk_source=full_chunk_source,
        audio_end_reference_valid=audio_end_reference_valid,
        llm_slot=LLM_FULL_SLOT,
        llm_slot_isolated=True,
        chunks=len(full_chunks),
        final_text_to_first_audio_ms=final_text_to_first_audio_ms,
        final_text_to_generation_done_ms=final_text_to_generation_done_ms,
        final_text_to_playback_done_ms=final_text_to_playback_done_ms,
        audio_end_to_first_audio_ms=audio_end_to_first_audio_ms,
        audio_end_to_generation_done_ms=audio_end_to_generation_done_ms,
        audio_end_to_playback_done_ms=audio_end_to_playback_done_ms,
        cache_warm_ms=int((cache_warm_done_at - final_text_at) * 1000),
        start_to_first_audio_ms=int((first_audio_at - full_started) * 1000),
        start_to_generation_done_ms=int((tts_generation_done_at - full_started) * 1000),
        start_to_playback_done_ms=int((playback_done_at - full_started) * 1000),
    )

    tts_baseline = synthesize(
        'This is a short Pocket TTS benchmark response.',
        'baseline',
        RUN_DIR / 'tts-baseline.wav',
    )

    cache_ms = [v * 1000 for v in cache_latencies]
    full_cache_ms = [v * 1000 for v in full_cache_latencies]
    asr_realtime_factor_raw = (
        asr_wall / input_info['duration_seconds'] if input_info['duration_seconds'] else None
    )
    first_tts_segment = tts_final['segments'][0]
    tail_tts_segments = tts_final['segments'][1:]
    first_segment_playback_end_at = (
        tts_final['first_audio_at'] + first_tts_segment['audio_seconds']
    )
    tail_first_audio_at = None
    if tail_tts_segments:
        tail_first_audio_at = (
            tail_tts_segments[0]['first_chunk_at'] or tail_tts_segments[0]['complete_at']
        )
    tail_ready_before_first_segment_playback_end = (
        tail_first_audio_at <= first_segment_playback_end_at
        if tail_first_audio_at is not None
        else None
    )
    total_tts_generation_seconds = sum(
        segment['generation_seconds'] for segment in tts_final['segments']
    )
    first_segment_text_chars = first_tts_segment['text_chars']
    tail_text_chars = tts_final['tail_text_chars']
    first_segment_audio_seconds = first_tts_segment['audio_seconds']
    tail_audio_seconds = tts_final['tail_audio_seconds']
    first_segment_generation_seconds = first_tts_segment['generation_seconds']
    tail_generation_seconds = tts_final['tail_generation_seconds']

    def p95(values: list[float]) -> float | None:
        if not values:
            return None
        index = min(len(values) - 1, max(0, math.ceil(0.95 * len(values)) - 1))
        return sorted(values)[index]

    llm_cache_comparison_valid = True
    full_pipeline_llm_cache_valid = True
    summary = {
        'run_id': RUN_ID,
        'audio_seconds': input_info['duration_seconds'],
        'asr_wall_seconds': asr_wall,
        'asr_realtime_factor': asr_realtime_factor_raw if asr_mode == 'realtime' else None,
        'asr_realtime_factor_raw': asr_realtime_factor_raw,
        'asr_mode': asr_mode,
        'asr_chunk_source': asr_chunk_source,
        'asr_backend': ASR_BACKEND_NAME,
        'asr_stream_strategy': asr_stream_strategy,
        'asr_stream_sample_rate': ASR_STREAM_SAMPLE_RATE,
        'asr_matches_stt_warmup': asr_matches_reference,
        'asr_first_chunk_ms': asr_first_chunk_ms,
        'chunk_count': len(chunks),
        'cache_warm_count': len(cache_latencies),
        'cache_warm_p50_ms': statistics.median(cache_ms) if cache_ms else None,
        'cache_warm_p95_ms': p95(cache_ms),
        'cache_warm_p50_ms_raw': statistics.median(cache_ms) if cache_ms else None,
        'cache_warm_p95_ms_raw': p95(cache_ms),
        'llm_slot_strategy': 'separate_slots_with_run_id',
        'llm_slot_assignments': LLM_SLOT_ASSIGNMENTS,
        'llm_cache_comparison_valid': llm_cache_comparison_valid,
        'full_pipeline_llm_cache_valid': full_pipeline_llm_cache_valid,
        'full_pipeline_chunk_source': full_chunk_source,
        'full_pipeline_asr_first_chunk_ms': full_asr_first_chunk_ms,
        'full_pipeline_asr_stream_strategy': full_asr_stream_strategy,
        'full_pipeline_asr_mode': full_asr_mode,
        'full_pipeline_asr_wall_seconds': full_asr_wall,
        'full_pipeline_asr_matches_stt_warmup': full_asr_matches_reference,
        'full_pipeline_cache_warm_timing': full_pipeline_cache_warm_timing,
        'full_pipeline_cache_warm_count': len(full_cache_latencies),
        'full_pipeline_cache_warm_p50_ms': statistics.median(full_cache_ms)
        if full_cache_ms
        else None,
        'full_pipeline_cache_warm_p95_ms': p95(full_cache_ms),
        'full_pipeline_cache_warm_wall_ms': int((cache_warm_done_at - final_text_at) * 1000),
        'full_pipeline_response_text_chars': len(response_text),
        'full_pipeline_response_text': response_text,
        'full_pipeline_response_raw': response_raw,
        'cold_final_ttft_ms': cold['ttft_ms'],
        'cached_final_ttft_ms': cached['ttft_ms'],
        'cold_final_ttft_ms_raw': cold['ttft_ms'],
        'cached_final_ttft_ms_raw': cached['ttft_ms'],
        'full_pipeline_audio_end_reference_valid': audio_end_reference_valid,
        'full_pipeline_final_ttft_from_audio_end_ms': (
            full_pipeline_final_ttft_from_audio_end_ms_raw
            if audio_end_reference_valid and full_pipeline_llm_cache_valid
            else None
        ),
        'full_pipeline_final_ttft_from_audio_end_ms_raw': full_pipeline_final_ttft_from_audio_end_ms_raw,
        'full_pipeline_final_ttft_from_final_text_ms': full_pipeline_final_ttft_from_final_text_ms_raw,
        'full_pipeline_final_ttft_from_final_text_ms_raw': full_pipeline_final_ttft_from_final_text_ms_raw,
        'full_pipeline_final_request_ttft_ms': tts_final['ttft_ms'],
        'decode_tokens_per_second': tts_final['predicted_per_second'],
        'full_pipeline_first_audio_chunk_from_audio_end_ms': (
            audio_end_to_first_audio_ms if audio_end_reference_valid else None
        ),
        'full_pipeline_first_audio_chunk_from_audio_end_ms_raw': audio_end_to_first_audio_ms,
        'full_pipeline_first_audio_chunk_from_final_text_ms': final_text_to_first_audio_ms,
        'full_pipeline_tts_generation_done_from_audio_end_ms': (
            audio_end_to_generation_done_ms if audio_end_reference_valid else None
        ),
        'full_pipeline_tts_generation_done_from_audio_end_ms_raw': (
            audio_end_to_generation_done_ms
        ),
        'full_pipeline_tts_generation_done_from_final_text_ms': (
            final_text_to_generation_done_ms
        ),
        'full_pipeline_playback_complete_from_audio_end_ms': (
            audio_end_to_playback_done_ms if audio_end_reference_valid else None
        ),
        'full_pipeline_playback_complete_from_audio_end_ms_raw': (
            audio_end_to_playback_done_ms
        ),
        'full_pipeline_playback_complete_from_final_text_ms': final_text_to_playback_done_ms,
        'tts_wall_seconds': tts_final['wall_seconds'],
        'tts_generation_seconds': tts_final['generation_seconds'],
        'tts_output_audio_seconds': tts_final['audio_seconds'],
        'tts_streaming_enabled': True,
        'tts_stream_segment_count': tts_final['segment_count'],
        'tts_stream_playback_seconds': tts_final['playback_seconds'],
        'tts_stream_playback_gap_seconds': tts_final['playback_gap_seconds'],
        'tts_stream_wall_realtime_factor': tts_final['stream_wall_realtime_factor'],
        'tts_first_audio_chunk_ms': first_tts_segment['first_chunk_ms'],
        'tts_input_first_sentence_ready_from_llm_request_ms': int(
            (tts_final['first_sentence_at'] - tts_final['llm_started_at']) * 1000,
        ),
        'tts_input_first_sentence_ready_from_final_text_ms': int(
            (tts_final['first_sentence_at'] - final_text_at) * 1000,
        ),
        'tts_input_first_sentence_ready_from_audio_end_ms': (
            int((tts_final['first_sentence_at'] - audio_end_at) * 1000)
            if audio_end_at is not None
            else None
        ),
        'tts_input_first_sentence_to_first_audio_ms': int(
            (tts_final['first_audio_at'] - tts_final['first_sentence_at']) * 1000,
        ),
        'tts_input_first_segment_text_chars': first_segment_text_chars,
        'tts_input_tail_text_chars': tail_text_chars,
        'tts_input_first_segment_text_ratio': tts_final['first_segment_text_ratio'],
        'tts_input_tail_text_ratio': (
            tail_text_chars / (first_segment_text_chars + tail_text_chars)
            if first_segment_text_chars + tail_text_chars > 0
            else None
        ),
        'tts_input_first_segment_audio_seconds': first_segment_audio_seconds,
        'tts_input_tail_audio_seconds': tail_audio_seconds,
        'tts_input_first_segment_audio_ratio': tts_final['first_segment_audio_ratio'],
        'tts_input_tail_audio_ratio': (
            tail_audio_seconds / (first_segment_audio_seconds + tail_audio_seconds)
            if first_segment_audio_seconds + tail_audio_seconds > 0
            else None
        ),
        'tts_input_first_segment_generation_seconds': first_segment_generation_seconds,
        'tts_input_tail_generation_seconds': tail_generation_seconds,
        'tts_input_first_segment_generation_ratio': (
            first_segment_generation_seconds / total_tts_generation_seconds
            if total_tts_generation_seconds > 0
            else None
        ),
        'tts_input_tail_generation_ratio': (
            tail_generation_seconds / total_tts_generation_seconds
            if total_tts_generation_seconds > 0
            else None
        ),
        'tts_input_tail_ready_before_first_segment_playback_end': (
            tail_ready_before_first_segment_playback_end
        ),
        'tts_realtime_factor': tts_final['realtime_factor'],
        'tts_baseline_realtime_factor': tts_baseline['realtime_factor'],
        'tts_warmup_wall_seconds': tts_warmup['wall_seconds'],
        'tts_warmup_generation_seconds': tts_warmup['generation_seconds'],
        'tts_warmup_audio_seconds': tts_warmup['audio_seconds'],
        'tts_warmup_realtime_factor': tts_warmup['realtime_factor'],
        'stt_warmup_wall_seconds': stt_warmup['wall_seconds'],
        'stt_warmup_transcript': stt_warmup['transcript'],
        'llm_warmup_text': llama_warmup['text'].strip(),
        'llm_warmup_ttft_ms': llama_warmup['ttft_ms'],
        'full_pipeline_spoken_response_from_audio_end_ms': (
            audio_end_to_first_audio_ms if audio_end_reference_valid else None
        ),
        'full_pipeline_spoken_response_from_final_text_ms': final_text_to_first_audio_ms,
        'asr_model': ASR_MODEL,
        'asr_trailing_silence_ms': ASR_TRAILING_SILENCE_MS,
        'asr_completion_grace_ms': ASR_COMPLETION_GRACE_MS,
        'llm_model': LLM_MODEL,
        'tts_model': TTS_MODEL,
        'asr_backend_image': 'python:3.11-bookworm + nemo_toolkit[asr]',
        'llama_server_image': 'ghcr.io/ggml-org/llama.cpp:server',
        'tts_backend_image': 'python:3.11-bookworm + pocket-tts==2.1.0',
        'results_dir': str(RUN_DIR),
        'notes': NOTES,
    }
    SUMMARY_PATH.write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    event('run_complete', summary=str(SUMMARY_PATH))
    print(json.dumps(summary, indent=2, sort_keys=True), flush=True)


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as exc:
        event('run_failed', error=repr(exc))
        raise
    finally:
        EVENTS.close()
