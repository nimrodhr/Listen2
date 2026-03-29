"""Audio device enumeration."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

import sounddevice as sd

logger = logging.getLogger("listen.audio.devices")


@dataclass
class AudioDevice:
    id: int
    name: str
    channels: int
    sample_rate: float
    is_input: bool


def list_input_devices() -> list[AudioDevice]:
    """List all available audio input devices."""
    devices = []
    try:
        for i, dev in enumerate(sd.query_devices()):
            if dev["max_input_channels"] > 0:
                devices.append(
                    AudioDevice(
                        id=i,
                        name=dev["name"],
                        channels=dev["max_input_channels"],
                        sample_rate=dev["default_samplerate"],
                        is_input=True,
                    )
                )
    except Exception as e:
        logger.error(f"Failed to enumerate input devices: {e}", exc_info=True)
    logger.info(f"Found {len(devices)} input devices")
    return devices


def get_default_mic() -> Optional[AudioDevice]:
    """Get the default microphone input device."""
    try:
        default_id = sd.default.device[0]
        if default_id is None or default_id < 0:
            logger.warning("No default microphone configured")
            return None
        dev = sd.query_devices(default_id)
        if dev["max_input_channels"] > 0:
            logger.info(f"Default mic: id={default_id}, name={dev['name']}")
            return AudioDevice(
                id=default_id,
                name=dev["name"],
                channels=dev["max_input_channels"],
                sample_rate=dev["default_samplerate"],
                is_input=True,
            )
    except Exception as e:
        logger.error(f"Failed to get default mic: {e}", exc_info=True)
    return None
