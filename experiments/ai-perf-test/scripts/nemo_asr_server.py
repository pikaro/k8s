import base64
import json
import os
import tempfile
import threading
import time
import wave
from contextlib import nullcontext
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket
from fastapi.responses import PlainTextResponse


def bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


ASR_MODEL = os.getenv(
    "ASR_MODEL",
    "nvidia/stt_en_fastconformer_hybrid_large_streaming_multi",
)
ASR_PORT = int(os.getenv("ASR_PORT", "8002"))
ASR_DEVICE = os.getenv("ASR_DEVICE", "cpu")
ASR_TORCH_THREADS = int(os.getenv("ASR_TORCH_THREADS", "4"))
ASR_DECODER_TYPE = os.getenv("ASR_DECODER_TYPE", "rnnt")
ASR_ATT_CONTEXT_SIZE = os.getenv("ASR_ATT_CONTEXT_SIZE", "[70,1]")
ASR_INPUT_AUDIO_SECONDS = float(
    os.getenv("ASR_INPUT_AUDIO_SECONDS", os.getenv("ASR_EMIT_AUDIO_SECONDS", "0.25")),
)
ASR_FINAL_FLUSH_SECONDS = float(
    os.getenv("ASR_FINAL_FLUSH_SECONDS", str(ASR_INPUT_AUDIO_SECONDS)),
)
ASR_PREPROCESS_HOLDBACK_SECONDS = float(
    os.getenv("ASR_PREPROCESS_HOLDBACK_SECONDS", "0.1"),
)
ASR_MIN_DELTA_CHARS = int(os.getenv("ASR_MIN_DELTA_CHARS", "1"))
ASR_ONLINE_NORMALIZATION = bool_env("ASR_ONLINE_NORMALIZATION")
ASR_PAD_AND_DROP_PREENCODED = bool_env("ASR_PAD_AND_DROP_PREENCODED")
ASR_STREAM_STRATEGY = "cache_aware_conformer_stream_step_continuous_features"


app = FastAPI()
model: Any | None = None
torch_module: Any | None = None
np_module: Any | None = None
streaming_buffer_cls: Any | None = None
loaded_at: float | None = None
load_error: str | None = None
model_lock = threading.Lock()


def parse_context_size(value: str) -> list[int] | None:
    if not value:
        return None
    try:
        parsed = json.loads(value)
    except ValueError:
        parsed = [item.strip() for item in value.split(",") if item.strip()]
    if not isinstance(parsed, list):
        raise ValueError("ASR_ATT_CONTEXT_SIZE must be a JSON list or comma list")
    return [int(item) for item in parsed]


def extract_text(result: Any) -> str:
    if isinstance(result, str):
        return result.strip()
    if isinstance(result, dict):
        value = result.get("text") or result.get("transcript")
        return str(value or "").strip()
    value = getattr(result, "text", None)
    if value is not None:
        return str(value).strip()
    return str(result or "").strip()


def extract_first_text(result: Any) -> str:
    if isinstance(result, (list, tuple)):
        if not result:
            return ""
        return extract_text(result[0])
    return extract_text(result)


def write_pcm_wav(path: Path, pcm: bytes, sample_rate: int, channels: int = 1) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)


def normalize_upload_to_file(data: bytes, suffix: str = ".wav") -> Path:
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    tmp.write(data)
    tmp.close()
    return Path(tmp.name)


def configure_model(asr_model: Any) -> None:
    if ASR_DECODER_TYPE and hasattr(asr_model, "change_decoding_strategy"):
        decoding_cfg = None
        try:
            if ASR_DECODER_TYPE == "rnnt":
                from nemo.collections.asr.parts.submodules.rnnt_decoding import (
                    RNNTDecodingConfig,
                )

                decoding_cfg = RNNTDecodingConfig(fused_batch_size=-1)
            elif ASR_DECODER_TYPE == "ctc":
                from nemo.collections.asr.parts.submodules.ctc_decoding import (
                    CTCDecodingConfig,
                )

                decoding_cfg = CTCDecodingConfig()
        except Exception as exc:
            print(f"ASR decoder config object unavailable: {exc!r}", flush=True)

        try:
            if decoding_cfg is not None:
                if hasattr(asr_model, "cur_decoder"):
                    asr_model.change_decoding_strategy(
                        decoding_cfg,
                        decoder_type=ASR_DECODER_TYPE,
                    )
                else:
                    asr_model.change_decoding_strategy(decoding_cfg)
            else:
                asr_model.change_decoding_strategy(decoder_type=ASR_DECODER_TYPE)
        except TypeError:
            try:
                asr_model.change_decoding_strategy(None, decoder_type=ASR_DECODER_TYPE)
            except Exception as exc:
                print(f"ASR decoder configuration skipped: {exc!r}", flush=True)
        except Exception as exc:
            print(f"ASR decoder configuration skipped: {exc!r}", flush=True)

    context_size = parse_context_size(ASR_ATT_CONTEXT_SIZE)
    if context_size and hasattr(asr_model, "encoder"):
        encoder = asr_model.encoder
        if hasattr(encoder, "set_default_att_context_size"):
            try:
                encoder.set_default_att_context_size(context_size)
            except Exception as exc:
                print(f"ASR attention context configuration skipped: {exc!r}", flush=True)

    preprocessor = getattr(asr_model, "preprocessor", None)
    featurizer = getattr(preprocessor, "featurizer", None)
    if featurizer is not None:
        if hasattr(featurizer, "dither"):
            featurizer.dither = 0.0
        if hasattr(featurizer, "pad_to"):
            featurizer.pad_to = 0

    if hasattr(asr_model, "freeze"):
        asr_model.freeze()
    if hasattr(asr_model, "eval"):
        asr_model.eval()


@app.on_event("startup")
def load_model() -> None:
    global model, torch_module, np_module, streaming_buffer_cls, loaded_at, load_error
    started = time.perf_counter()
    try:
        import numpy as np
        import torch
        import nemo.collections.asr as nemo_asr
        from nemo.collections.asr.parts.utils.streaming_utils import (
            CacheAwareStreamingAudioBuffer,
        )

        torch.set_num_threads(ASR_TORCH_THREADS)
        torch.set_grad_enabled(False)
        torch_module = torch
        np_module = np
        streaming_buffer_cls = CacheAwareStreamingAudioBuffer
        asr_model = nemo_asr.models.ASRModel.from_pretrained(model_name=ASR_MODEL)
        configure_model(asr_model)
        if hasattr(asr_model, "to"):
            asr_model = asr_model.to(ASR_DEVICE)
        model = asr_model
        loaded_at = time.perf_counter() - started
        load_error = None
    except Exception as exc:
        load_error = repr(exc)
        raise


def transcribe_file(path: Path) -> str:
    if model is None:
        raise HTTPException(status_code=503, detail="ASR model is still loading")
    kwargs: dict[str, Any] = {"batch_size": 1}
    with model_lock:
        with torch_module.inference_mode() if torch_module is not None else nullcontext():
            try:
                result = model.transcribe([str(path)], **kwargs)
            except TypeError:
                result = model.transcribe([str(path)])
    if isinstance(result, tuple):
        result = result[0]
    if isinstance(result, list):
        if not result:
            return ""
        return extract_text(result[0])
    return extract_text(result)


def transcribe_pcm(pcm: bytes, sample_rate: int) -> str:
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    path = Path(tmp.name)
    tmp.close()
    try:
        write_pcm_wav(path, pcm, sample_rate)
        return transcribe_file(path)
    finally:
        path.unlink(missing_ok=True)


def transcript_delta(previous: str, current: str) -> str:
    if not previous:
        return current.strip()
    if current.startswith(previous):
        return current[len(previous) :].strip()
    return ""


def stable_word_prefix(previous: str, current: str) -> str:
    limit = min(len(previous), len(current))
    common_len = 0
    while common_len < limit and previous[common_len] == current[common_len]:
        common_len += 1
    if common_len == 0:
        return ""

    prefix = current[:common_len]
    if common_len < len(current) and not current[common_len].isspace():
        if prefix.endswith(" "):
            return prefix.strip()
        boundary = prefix.rstrip().rfind(" ")
        if boundary < 0:
            return ""
        prefix = prefix[:boundary]
    return prefix.strip()


def model_sample_rate() -> int | None:
    if model is None:
        return None
    cfg = getattr(model, "cfg", None) or getattr(model, "_cfg", None)
    if cfg is None:
        return None
    value = getattr(cfg, "sample_rate", None)
    if value is None and hasattr(cfg, "get"):
        value = cfg.get("sample_rate")
    return int(value) if value else None


def drop_extra_pre_encoded(step_num: int) -> int:
    if step_num == 0 and not ASR_PAD_AND_DROP_PREENCODED:
        return 0
    encoder = getattr(model, "encoder", None)
    streaming_cfg = getattr(encoder, "streaming_cfg", None)
    return int(getattr(streaming_cfg, "drop_extra_pre_encoded", 0) or 0)


def pcm16_to_float32(pcm: bytes, channels: int) -> Any:
    if np_module is None:
        raise RuntimeError("numpy is unavailable")
    samples = np_module.frombuffer(pcm, dtype="<i2").astype(np_module.float32) / 32768.0
    if channels > 1:
        usable = samples.size - (samples.size % channels)
        samples = samples[:usable].reshape(-1, channels).mean(axis=1)
    return samples


class CacheAwareStreamingSession:
    def __init__(self, sample_rate: int, channels: int) -> None:
        if model is None or torch_module is None or streaming_buffer_cls is None:
            raise RuntimeError("ASR model is still loading")
        if channels < 1:
            raise ValueError("input_audio_channels must be at least 1")
        expected_sample_rate = model_sample_rate()
        if expected_sample_rate is not None and sample_rate != expected_sample_rate:
            raise ValueError(
                f"expected {expected_sample_rate} Hz PCM, got {sample_rate} Hz",
            )

        self.sample_rate = sample_rate
        self.channels = channels
        self.input_chunk_bytes = max(
            channels * 2,
            int(sample_rate * ASR_INPUT_AUDIO_SECONDS) * channels * 2,
        )
        self.holdback_feature_frames = self._seconds_to_feature_frames(
            ASR_PREPROCESS_HOLDBACK_SECONDS,
        )
        self.raw_pcm = bytearray()
        self.unprocessed_bytes = 0
        self.appended_feature_frames = 0
        self.stream_id = -1
        self.streaming_buffer = streaming_buffer_cls(
            model=model,
            online_normalization=ASR_ONLINE_NORMALIZATION,
            pad_and_drop_preencoded=ASR_PAD_AND_DROP_PREENCODED,
        )
        (
            self.cache_last_channel,
            self.cache_last_time,
            self.cache_last_channel_len,
        ) = model.encoder.get_initial_cache_state(batch_size=1)
        self.previous_hypotheses = None
        self.pred_out_stream = None
        self.step_num = 0
        self.emitted_text = ""
        self.previous_transcript = ""
        self.latest_transcript = ""

    def append_pcm(self, pcm: bytes) -> list[dict[str, Any]]:
        self.raw_pcm.extend(pcm)
        self.unprocessed_bytes += len(pcm)
        messages: list[dict[str, Any]] = []
        if self.unprocessed_bytes >= self.input_chunk_bytes:
            with model_lock:
                self._append_ready_features(final=False)
                messages.extend(self._process_ready_locked(final=False))
            self.unprocessed_bytes = 0
        return messages

    def finish(self) -> list[dict[str, Any]]:
        with model_lock:
            if (
                ASR_FINAL_FLUSH_SECONDS > 0
                and self.raw_pcm
            ):
                flush_samples = max(1, int(self.sample_rate * ASR_FINAL_FLUSH_SECONDS))
                self.raw_pcm.extend(b"\x00\x00" * flush_samples * self.channels)
            self._append_ready_features(final=True)
            messages = self._process_ready_locked(final=True)
        completed = self.latest_transcript or self.emitted_text
        if completed:
            messages.append(
                {
                    "type": "conversation.item.input_audio_transcription.completed",
                    "transcript": completed,
                    "source": ASR_STREAM_STRATEGY,
                },
            )
        return messages

    def _seconds_to_feature_frames(self, seconds: float) -> int:
        if seconds <= 0:
            return 0
        cfg = getattr(model, "cfg", None) or getattr(model, "_cfg", None)
        preprocessor_cfg = getattr(cfg, "preprocessor", None) if cfg is not None else None
        window_stride = None
        if preprocessor_cfg is not None:
            window_stride = getattr(preprocessor_cfg, "window_stride", None)
            if window_stride is None and hasattr(preprocessor_cfg, "get"):
                window_stride = preprocessor_cfg.get("window_stride")
        if not window_stride:
            return 0
        return max(0, int(seconds / float(window_stride)))

    def _append_ready_features(self, final: bool) -> None:
        audio = pcm16_to_float32(bytes(self.raw_pcm), self.channels)
        if audio.size == 0:
            return
        processed_signal, processed_signal_length = self.streaming_buffer.preprocess_audio(audio)
        total_frames = int(processed_signal_length.item())
        ready_frames = total_frames if final else max(0, total_frames - self.holdback_feature_frames)
        if ready_frames <= self.appended_feature_frames:
            return
        new_signal = processed_signal[:, :, self.appended_feature_frames : ready_frames]
        _, _, stream_id = self.streaming_buffer.append_processed_signal(
            new_signal,
            stream_id=self.stream_id,
        )
        self.stream_id = 0 if stream_id < 0 else stream_id
        self.appended_feature_frames = ready_frames

    def _process_ready_locked(self, final: bool) -> list[dict[str, Any]]:
        messages: list[dict[str, Any]] = []
        if getattr(self.streaming_buffer, "buffer", None) is None:
            return messages

        for chunk_audio, chunk_lengths in self.streaming_buffer:
            with torch_module.inference_mode():
                chunk_audio = chunk_audio.to(torch_module.float32)
                (
                    self.pred_out_stream,
                    transcribed_texts,
                    self.cache_last_channel,
                    self.cache_last_time,
                    self.cache_last_channel_len,
                    self.previous_hypotheses,
                ) = model.conformer_stream_step(
                    processed_signal=chunk_audio,
                    processed_signal_length=chunk_lengths,
                    cache_last_channel=self.cache_last_channel,
                    cache_last_time=self.cache_last_time,
                    cache_last_channel_len=self.cache_last_channel_len,
                    keep_all_outputs=final and self.streaming_buffer.is_buffer_empty(),
                    previous_hypotheses=self.previous_hypotheses,
                    previous_pred_out=self.pred_out_stream,
                    drop_extra_pre_encoded=drop_extra_pre_encoded(self.step_num),
                    return_transcription=True,
                )
            self.step_num += 1
            transcript = extract_first_text(transcribed_texts)
            if not transcript:
                continue
            emit_transcript = (
                transcript if final else stable_word_prefix(self.previous_transcript, transcript)
            )
            self.previous_transcript = transcript
            self.latest_transcript = transcript
            delta = transcript_delta(self.emitted_text, emit_transcript)
            if delta and len(delta) >= ASR_MIN_DELTA_CHARS:
                self.emitted_text = emit_transcript
                messages.append(
                    {
                        "type": "conversation.item.input_audio_transcription.delta",
                        "delta": delta,
                        "transcript": emit_transcript,
                        "source": ASR_STREAM_STRATEGY,
                    },
                )
            elif not final:
                messages.append(
                    {
                        "type": "conversation.item.input_audio_transcription.partial",
                        "transcript": transcript,
                        "source": ASR_STREAM_STRATEGY,
                    },
                )
        return messages


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok" if model is not None else "loading",
        "backend": "nemo",
        "model": ASR_MODEL,
        "device": ASR_DEVICE,
        "decoder_type": ASR_DECODER_TYPE,
        "att_context_size": ASR_ATT_CONTEXT_SIZE,
        "streaming": True,
        "stream_endpoint": "/v1/realtime",
        "stream_strategy": ASR_STREAM_STRATEGY,
        "input_audio_seconds": ASR_INPUT_AUDIO_SECONDS,
        "final_flush_seconds": ASR_FINAL_FLUSH_SECONDS,
        "preprocess_holdback_seconds": ASR_PREPROCESS_HOLDBACK_SECONDS,
        "online_normalization": ASR_ONLINE_NORMALIZATION,
        "pad_and_drop_preencoded": ASR_PAD_AND_DROP_PREENCODED,
        "sample_rate": model_sample_rate(),
        "load_seconds": loaded_at,
        "load_error": load_error,
    }


@app.post("/v1/models/{model_id:path}")
def ensure_model(model_id: str) -> PlainTextResponse:
    if model is None:
        raise HTTPException(status_code=503, detail="ASR model is still loading")
    if model_id and model_id != ASR_MODEL:
        raise HTTPException(
            status_code=400,
            detail=f"loaded model is {ASR_MODEL}, not {model_id}",
        )
    return PlainTextResponse(f"Model '{ASR_MODEL}' is ready")


@app.post("/v1/audio/transcriptions")
async def transcribe_http(
    file: UploadFile = File(...),
    model_name: str = Form(default="", alias="model"),
) -> PlainTextResponse:
    if model_name and model_name != ASR_MODEL:
        raise HTTPException(
            status_code=400,
            detail=f"loaded model is {ASR_MODEL}, not {model_name}",
        )
    data = await file.read()
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    path = normalize_upload_to_file(data, suffix=suffix)
    try:
        transcript = transcribe_file(path)
    finally:
        path.unlink(missing_ok=True)
    return PlainTextResponse(transcript)


@app.websocket("/v1/realtime")
async def realtime(ws: WebSocket) -> None:
    await ws.accept()
    sample_rate = int(os.getenv("ASR_STREAM_SAMPLE_RATE", "16000"))
    channels = 1
    stream_session: CacheAwareStreamingSession | None = None

    def get_stream_session() -> CacheAwareStreamingSession:
        nonlocal stream_session
        if stream_session is None:
            stream_session = CacheAwareStreamingSession(sample_rate, channels)
        return stream_session

    while True:
        raw = await ws.receive_text()
        try:
            data = json.loads(raw)
        except ValueError:
            await ws.send_json(
                {"type": "error", "message": "expected JSON websocket messages"},
            )
            continue

        msg_type = str(data.get("type", ""))
        if msg_type == "session.update":
            session = data.get("session") if isinstance(data.get("session"), dict) else {}
            if stream_session is not None:
                await ws.send_json(
                    {
                        "type": "error",
                        "message": "session.update is only supported before audio",
                    },
                )
                continue
            sample_rate = int(session.get("input_audio_sample_rate", sample_rate))
            channels = int(session.get("input_audio_channels", channels))
            await ws.send_json({"type": "session.updated", "session": health()})
            continue
        if msg_type in {"input_audio_buffer.append", "audio"}:
            encoded = data.get("audio")
            if not isinstance(encoded, str):
                await ws.send_json({"type": "error", "message": "missing audio"})
                continue
            try:
                messages = get_stream_session().append_pcm(base64.b64decode(encoded))
            except Exception as exc:
                await ws.send_json({"type": "error", "message": repr(exc)})
                return
            for message in messages:
                await ws.send_json(message)
            continue
        if msg_type in {"input_audio_buffer.commit", "eof"}:
            try:
                messages = get_stream_session().finish()
            except Exception as exc:
                await ws.send_json({"type": "error", "message": repr(exc)})
                return
            for message in messages:
                await ws.send_json(message)
            return
        await ws.send_json({"type": "error", "message": f"unsupported event {msg_type}"})


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=ASR_PORT)
