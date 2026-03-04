"""Resample audio to PCM 16-bit 24kHz mono for OpenAI Realtime API."""

from __future__ import annotations

import numpy as np
import soxr


TARGET_SAMPLE_RATE = 24000


class Resampler:
    """Resamples audio from a source sample rate to 24kHz PCM16 mono."""

    def __init__(self, source_rate: float, channels: int = 1) -> None:
        self.source_rate = source_rate
        self.channels = channels
        self._resampler = (
            soxr.ResampleStream(source_rate, TARGET_SAMPLE_RATE, 1, dtype=np.int16)
            if source_rate != TARGET_SAMPLE_RATE
            else None
        )

    def process(self, pcm_data: bytes) -> bytes:
        """Resample raw PCM bytes and return 24kHz mono PCM16 bytes."""
        audio = np.frombuffer(pcm_data, dtype=np.int16)

        # Downmix to mono if stereo
        if self.channels > 1:
            audio = audio.reshape(-1, self.channels).mean(axis=1).astype(np.int16)

        if self._resampler is None:
            return audio.tobytes()

        resampled = self._resampler.resample_chunk(audio)
        return resampled.tobytes()
