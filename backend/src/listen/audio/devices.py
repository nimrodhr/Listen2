"""Audio device enumeration and BlackHole detection."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

import sounddevice as sd

logger = logging.getLogger("listen.audio.devices")

BLACKHOLE_NAMES = ("BlackHole 2ch", "BlackHole 16ch", "BlackHole")


@dataclass
class AudioDevice:
    id: int
    name: str
    channels: int
    sample_rate: float
    is_input: bool
    is_blackhole: bool = False


def list_input_devices() -> list[AudioDevice]:
    """List all available audio input devices."""
    devices = []
    try:
        for i, dev in enumerate(sd.query_devices()):
            if dev["max_input_channels"] > 0:
                is_bh = any(name in dev["name"] for name in BLACKHOLE_NAMES)
                devices.append(
                    AudioDevice(
                        id=i,
                        name=dev["name"],
                        channels=dev["max_input_channels"],
                        sample_rate=dev["default_samplerate"],
                        is_input=True,
                        is_blackhole=is_bh,
                    )
                )
    except Exception as e:
        logger.error(f"Failed to enumerate input devices: {e}", exc_info=True)
    logger.info(f"Found {len(devices)} input devices")
    return devices


def list_output_devices() -> list[AudioDevice]:
    """List all available audio output devices."""
    devices = []
    try:
        for i, dev in enumerate(sd.query_devices()):
            if dev["max_output_channels"] > 0:
                devices.append(
                    AudioDevice(
                        id=i,
                        name=dev["name"],
                        channels=dev["max_output_channels"],
                        sample_rate=dev["default_samplerate"],
                        is_input=False,
                    )
                )
    except Exception as e:
        logger.error(f"Failed to enumerate output devices: {e}", exc_info=True)
    logger.info(f"Found {len(devices)} output devices")
    return devices


def list_loopback_devices() -> list[AudioDevice]:
    """List devices suitable for system audio loopback capture.

    These must have input channels (since they're opened as InputStream)
    and are typically virtual audio devices like BlackHole.
    """
    devices = []
    try:
        for i, dev in enumerate(sd.query_devices()):
            if dev["max_input_channels"] > 0 and dev["max_output_channels"] > 0:
                is_bh = any(name in dev["name"] for name in BLACKHOLE_NAMES)
                devices.append(
                    AudioDevice(
                        id=i,
                        name=dev["name"],
                        channels=dev["max_input_channels"],
                        sample_rate=dev["default_samplerate"],
                        is_input=True,
                        is_blackhole=is_bh,
                    )
                )
    except Exception as e:
        logger.error(f"Failed to enumerate loopback devices: {e}", exc_info=True)
    logger.info(f"Found {len(devices)} loopback devices")
    return devices


def find_blackhole_device() -> Optional[AudioDevice]:
    """Find a BlackHole input device, if installed."""
    for dev in list_input_devices():
        if dev.is_blackhole:
            logger.info(f"BlackHole device found: id={dev.id}, name={dev.name}")
            return dev
    logger.info("BlackHole device not found")
    return None


def is_blackhole_installed() -> bool:
    """Check if BlackHole virtual audio driver is installed."""
    return find_blackhole_device() is not None


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
