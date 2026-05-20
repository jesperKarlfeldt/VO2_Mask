"""Protocol helpers for breathing/HRM + IMU payload decoding."""

from __future__ import annotations

import struct
from dataclasses import dataclass

BREATH_SAMPLE_SIZE = 8
IMU_SAMPLE_SIZE = 16
UINT32_MODULO = 1 << 32
UINT32_HALF_RANGE = 1 << 31
ACCEL_G_PER_LSB = 0.000122
GYRO_DPS_PER_LSB = 0.0175
GRAVITY = 9.80665


@dataclass(frozen=True)
class BreathingSample:
    sample_count: int
    breathing: int


@dataclass(frozen=True)
class ImuSample:
    sample_count: int
    ax: int
    ay: int
    az: int
    gx: int
    gy: int
    gz: int


@dataclass(frozen=True)
class ImuConverted:
    ax_g: float
    ay_g: float
    az_g: float
    gx_dps: float
    gy_dps: float
    gz_dps: float
    ax_ms2: float
    ay_ms2: float
    az_ms2: float


def convert_raw_imu(ax: int, ay: int, az: int, gx: int, gy: int, gz: int) -> ImuConverted:
    ax_g = ax * ACCEL_G_PER_LSB
    ay_g = ay * ACCEL_G_PER_LSB
    az_g = az * ACCEL_G_PER_LSB
    gx_dps = gx * GYRO_DPS_PER_LSB
    gy_dps = gy * GYRO_DPS_PER_LSB
    gz_dps = gz * GYRO_DPS_PER_LSB
    return ImuConverted(
        ax_g=ax_g,
        ay_g=ay_g,
        az_g=az_g,
        gx_dps=gx_dps,
        gy_dps=gy_dps,
        gz_dps=gz_dps,
        ax_ms2=ax_g * GRAVITY,
        ay_ms2=ay_g * GRAVITY,
        az_ms2=az_g * GRAVITY,
    )


def decode_breath_payload(payload: bytes) -> list[BreathingSample]:
    """Decode batched breathing payload (<Ii> repeated)."""
    if len(payload) % BREATH_SAMPLE_SIZE != 0:
        raise ValueError(
            f"Breathing payload length {len(payload)} is not a multiple of {BREATH_SAMPLE_SIZE}"
        )
    samples: list[BreathingSample] = []
    for sample_count, breathing in struct.iter_unpack("<Ii", payload):
        samples.append(
            BreathingSample(
                sample_count=sample_count,
                breathing=breathing,
            )
        )
    return samples


def decode_imu_payload(payload: bytes) -> list[ImuSample]:
    """Decode batched IMU payload (<Ihhhhhh> repeated)."""
    if len(payload) % IMU_SAMPLE_SIZE != 0:
        raise ValueError(
            f"IMU payload length {len(payload)} is not a multiple of {IMU_SAMPLE_SIZE}"
        )
    samples: list[ImuSample] = []
    for sample_count, ax, ay, az, gx, gy, gz in struct.iter_unpack("<Ihhhhhh", payload):
        samples.append(
            ImuSample(
                sample_count=sample_count,
                ax=ax,
                ay=ay,
                az=az,
                gx=gx,
                gy=gy,
                gz=gz,
            )
        )
    return samples


def decode_hrm_payload(payload: bytes) -> tuple[int, list[int]]:
    """Decode HRM 0x2A37 payload and return (bpm, rr_intervals_ms)."""
    if len(payload) < 2:
        raise ValueError("HRM payload must include flags and heart rate")
    flags = payload[0]
    idx = 1
    if flags & 0x01:
        if len(payload) < idx + 2:
            raise ValueError("HRM payload missing 16-bit heart rate")
        bpm = struct.unpack_from("<H", payload, idx)[0]
        idx += 2
    else:
        bpm = payload[idx]
        idx += 1

    if flags & 0x08:
        if len(payload) < idx + 2:
            raise ValueError("HRM payload missing energy expended field")
        idx += 2

    rr_ms_values: list[int] = []
    rr_present = bool(flags & 0x10)
    if rr_present:
        remaining = len(payload) - idx
        if remaining <= 0 or remaining % 2 != 0:
            raise ValueError("HRM RR-interval field has invalid length")
        while idx + 2 <= len(payload):
            rr_1024 = struct.unpack_from("<H", payload, idx)[0]
            rr_ms_values.append(int(round((rr_1024 * 1000.0) / 1024.0)))
            idx += 2
    elif idx != len(payload):
        raise ValueError("HRM payload has unexpected trailing bytes")

    return bpm, rr_ms_values


def decode_hr_payload(payload: bytes) -> int:
    """Decode HR payload (preferred: HRM 0x2A37, legacy: single signed byte)."""
    if len(payload) == 1:
        return struct.unpack("<b", payload)[0]
    bpm, _ = decode_hrm_payload(payload)
    return bpm


def decode_hrv_payload(payload: bytes) -> int:
    """Decode a single little-endian uint16 HRV RR interval (ms)."""
    if len(payload) != 2:
        raise ValueError("HRV payload length must be exactly 2 bytes")
    return struct.unpack("<H", payload)[0]


class SampleGapTracker:
    """Track missing sample_count values for uint32 sample streams."""

    def __init__(self):
        self._last_sample_count: int | None = None
        self.gaps = 0
        self.duplicates = 0
        self.out_of_order = 0

    def observe(self, sample_count: int) -> int:
        if self._last_sample_count is None:
            self._last_sample_count = sample_count
            return 0
        delta = (sample_count - self._last_sample_count) % UINT32_MODULO
        if delta == 0:
            self.duplicates += 1
            return 0
        if delta >= UINT32_HALF_RANGE:
            self.out_of_order += 1
            return 0
        missing = delta - 1
        if missing > 0:
            self.gaps += missing
        self._last_sample_count = sample_count
        return missing
