import io
import os
import threading
import time
import wave
from typing import Any

import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel

from pocket_tts import TTSModel


class SynthesizeRequest(BaseModel):
    text: str
    audio_prompt_path: str | None = None


app = FastAPI()
model: TTSModel | None = None
voice_state: dict[str, Any] | None = None
loaded_at: float | None = None
voice_loaded_at: float | None = None
generation_lock = threading.Lock()


def wav_duration_seconds(data: bytes) -> float:
    with wave.open(io.BytesIO(data), "rb") as wav:
        return wav.getnframes() / float(wav.getframerate())


def pcm16_bytes(audio: torch.Tensor) -> bytes:
    tensor = audio.detach().cpu().flatten()
    if tensor.dtype.is_floating_point:
        max_abs = float(tensor.abs().max()) if tensor.numel() else 0.0
        if max_abs <= 1.5:
            tensor = tensor.clamp(-1.0, 1.0).mul(32767.0)
        else:
            tensor = tensor.clamp(-32768.0, 32767.0)
    tensor = tensor.to(torch.int16).contiguous()
    return tensor.numpy().tobytes()


def wav_bytes(sample_rate: int, audio: torch.Tensor) -> bytes:
    pcm = pcm16_bytes(audio)

    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return output.getvalue()


@app.on_event("startup")
def load_model() -> None:
    global model, voice_state, loaded_at, voice_loaded_at
    torch.set_num_threads(int(os.getenv("TTS_THREADS", "2")))
    language = os.getenv("TTS_LANGUAGE", "english")
    voice = os.getenv("TTS_VOICE", "alba")
    started = time.perf_counter()
    model = TTSModel.load_model(language=language)
    loaded_at = time.perf_counter() - started

    started = time.perf_counter()
    voice_state = model.get_state_for_audio_prompt(voice)
    voice_loaded_at = time.perf_counter() - started


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok" if model is not None and voice_state is not None else "loading",
        "model": "kyutai/pocket-tts",
        "voice": os.getenv("TTS_VOICE", "alba"),
        "language": os.getenv("TTS_LANGUAGE", "english"),
        "streaming": True,
        "stream_endpoint": "/synthesize_stream",
        "load_seconds": loaded_at,
        "voice_load_seconds": voice_loaded_at,
    }


@app.post("/synthesize")
def synthesize(req: SynthesizeRequest) -> Response:
    if model is None or voice_state is None:
        raise HTTPException(status_code=503, detail="model is still loading")
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    started = time.perf_counter()
    state = voice_state
    if req.audio_prompt_path:
        state = model.get_state_for_audio_prompt(req.audio_prompt_path)
    with generation_lock:
        wav_tensor = model.generate_audio(state, text)
    generated_seconds = time.perf_counter() - started

    output_bytes = wav_bytes(model.sample_rate, wav_tensor)
    audio_seconds = wav_duration_seconds(output_bytes)

    headers = {
        "X-TTS-Wall-Seconds": f"{generated_seconds:.6f}",
        "X-TTS-Audio-Seconds": f"{audio_seconds:.6f}",
        "X-TTS-Realtime-Factor": f"{generated_seconds / audio_seconds:.6f}"
        if audio_seconds > 0
        else "0",
    }
    return Response(content=output_bytes, media_type="audio/wav", headers=headers)


@app.post("/synthesize_stream")
def synthesize_stream(req: SynthesizeRequest) -> StreamingResponse:
    if model is None or voice_state is None:
        raise HTTPException(status_code=503, detail="model is still loading")
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    state = voice_state
    if req.audio_prompt_path:
        state = model.get_state_for_audio_prompt(req.audio_prompt_path)

    def generate():
        # Pocket TTS is not thread-safe for concurrent generation on one model.
        with generation_lock:
            for audio_chunk in model.generate_audio_stream(state, text):
                chunk = pcm16_bytes(audio_chunk)
                if chunk:
                    yield chunk

    headers = {
        "X-TTS-Format": "pcm_s16le",
        "X-TTS-Sample-Rate": str(model.sample_rate),
        "X-TTS-Sample-Width": "2",
        "X-TTS-Channels": "1",
    }
    return StreamingResponse(
        generate(),
        media_type="application/octet-stream",
        headers=headers,
    )


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("TTS_PORT", "8001")))
