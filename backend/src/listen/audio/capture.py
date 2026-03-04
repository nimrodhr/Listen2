"""Dual audio capture from microphone and system audio (BlackHole)."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Optional, Callable

import numpy as np
import sounddevice as sd

from listen.audio.resampler import Resampler

logger = logging.getLogger("listen.audio.capture")


class AudioStream:
    """Captures audio from a single device and feeds resampled PCM16 24kHz mono chunks
    into an asyncio queue."""

    def __init__(
        self,
        device_id: int,
        label: str,
        loop: asyncio.AbstractEventLoop,
        chunk_duration_ms: int = 100,
    ) -> None:
        self.device_id = device_id
        self.label = label
        self._loop = loop
        self._chunk_duration_ms = chunk_duration_ms
        self._stream: Optional[sd.InputStream] = None
        self._resampler: Optional[Resampler] = None
        self.queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=200)
        self._callback_count = 0
        self._last_level_log = 0.0
        self._peak_since_log = 0
        self._zero_log_count = 0

    def start(self) -> None:
        """Open the audio stream and begin capturing."""
        dev_info = sd.query_devices(self.device_id)
        native_rate = dev_info["default_samplerate"]
        max_ch = dev_info["max_input_channels"]
        if max_ch < 1:
            raise RuntimeError(
                f"[{self.label}] Device {self.device_id} ({dev_info.get('name', '?')}) "
                f"reports 0 input channels — it may be an output-only device or "
                f"not properly configured"
            )
        channels = min(max_ch, 2)
        blocksize = int(native_rate * self._chunk_duration_ms / 1000)

        self._resampler = Resampler(native_rate, channels)

        self._stream = sd.InputStream(
            device=self.device_id,
            channels=channels,
            samplerate=native_rate,
            dtype="int16",
            blocksize=blocksize,
            callback=self._audio_callback,
        )
        self._stream.start()
        logger.info(
            f"[{self.label}] Audio stream started: device={self.device_id}, "
            f"rate={native_rate}, channels={channels}, blocksize={blocksize}"
        )

    def _audio_callback(
        self,
        indata: np.ndarray,
        frames: int,
        time_info: dict,
        status: sd.CallbackFlags,
    ) -> None:
        """PortAudio callback — runs in a separate thread. Must not block."""
        if status:
            # Defer logging off the real-time audio thread
            self._loop.call_soon_threadsafe(
                logger.warning, "[%s] Audio status: %s", self.label, status
            )

        # Log audio level every 2 seconds for diagnostics
        self._callback_count += 1
        peak = int(np.max(np.abs(indata)))
        self._peak_since_log = max(self._peak_since_log, peak)
        now = time.monotonic()
        if now - self._last_level_log >= 2.0:
            p = self._peak_since_log
            c = self._callback_count
            if p == 0:
                self._zero_log_count += 1
                log_fn = logger.info if self._zero_log_count < 3 else logger.warning
                msg = "[%s] Audio level: peak=%d/32767, callbacks=%d"
                if self._zero_log_count >= 3:
                    msg += " — receiving silence; check microphone permissions in System Settings > Privacy & Security > Microphone"
                self._loop.call_soon_threadsafe(log_fn, msg, self.label, p, c)
            else:
                self._zero_log_count = 0
                self._loop.call_soon_threadsafe(
                    logger.info,
                    "[%s] Audio level: peak=%d/32767, callbacks=%d",
                    self.label, p, c,
                )
            self._peak_since_log = 0
            self._last_level_log = now

        pcm_bytes = indata.tobytes()

        if self._resampler:
            pcm_bytes = self._resampler.process(pcm_bytes)

        try:
            self._loop.call_soon_threadsafe(self.queue.put_nowait, pcm_bytes)
        except asyncio.QueueFull:
            pass  # Drop frame rather than block the audio thread

    def stop(self) -> None:
        """Stop and close the audio stream."""
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
            logger.info(f"[{self.label}] Audio stream stopped")

    @property
    def is_active(self) -> bool:
        return self._stream is not None and self._stream.active


class AudioCapture:
    """Manages dual audio capture: microphone (user) and system audio (BlackHole)."""

    def __init__(
        self,
        mic_device_id: int,
        system_device_id: int,
        loop: asyncio.AbstractEventLoop,
        chunk_duration_ms: int = 100,
    ) -> None:
        self.mic_stream = AudioStream(
            device_id=mic_device_id,
            label="mic",
            loop=loop,
            chunk_duration_ms=chunk_duration_ms,
        )
        self.system_stream = AudioStream(
            device_id=system_device_id,
            label="system",
            loop=loop,
            chunk_duration_ms=chunk_duration_ms,
        )

    def start(self) -> None:
        """Start both audio streams."""
        self.mic_stream.start()
        self.system_stream.start()
        logger.info("Dual audio capture started")

    def stop(self) -> None:
        """Stop both audio streams."""
        self.mic_stream.stop()
        self.system_stream.stop()
        logger.info("Dual audio capture stopped")

    @property
    def is_active(self) -> bool:
        return self.mic_stream.is_active or self.system_stream.is_active
