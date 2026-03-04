"""BlackHole audio setup detection and instructions."""

from __future__ import annotations

import logging
from dataclasses import dataclass

from listen.audio.devices import is_blackhole_installed, find_blackhole_device

logger = logging.getLogger("listen.audio.setup_assistant")


@dataclass
class AudioSetupStatus:
    blackhole_installed: bool
    multi_output_configured: bool
    blackhole_device_id: int | None
    instructions: list[str] | None


SETUP_INSTRUCTIONS = [
    "1. Download BlackHole from https://existential.audio/blackhole/ (choose BlackHole 2ch)",
    "2. Install BlackHole by running the downloaded .pkg file",
    "3. Open Audio MIDI Setup (Applications > Utilities > Audio MIDI Setup)",
    "4. Click the '+' button at the bottom-left and choose 'Create Multi-Output Device'",
    "5. In the Multi-Output Device, check both 'Built-in Output' (or your speakers) AND 'BlackHole 2ch'",
    "6. Make sure 'Built-in Output' is listed FIRST (drag to reorder if needed)",
    "7. Right-click the Multi-Output Device and select 'Use This Device For Sound Output'",
    "8. BlackHole 2ch will now appear as an input device — select it as 'System Audio' in Listen settings",
]


def check_audio_setup() -> AudioSetupStatus:
    """Check the current macOS audio setup for BlackHole."""
    logger.info("Checking audio setup...")
    bh_installed = is_blackhole_installed()
    bh_device = find_blackhole_device()

    if not bh_installed:
        logger.warning("BlackHole not installed — setup instructions will be shown")
        return AudioSetupStatus(
            blackhole_installed=False,
            multi_output_configured=False,
            blackhole_device_id=None,
            instructions=SETUP_INSTRUCTIONS,
        )

    logger.info(f"Audio setup OK: blackhole_installed=True, device_id={bh_device.id if bh_device else None}")
    return AudioSetupStatus(
        blackhole_installed=True,
        multi_output_configured=bh_device is not None,
        blackhole_device_id=bh_device.id if bh_device else None,
        instructions=None,
    )
