from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

MERGED_CSV_HEADER = (
    "timestamp",
    "session_elapsed_s",
    "mask_t_s",
    "pulse_elapsed_s",
    "mask_sample_idx",
    "imu_sample_idx",
    "ecg_heart_adc",
    "ecg_breath_adc",
    "accel_x_g",
    "accel_y_g",
    "accel_z_g",
    "gyro_x_dps",
    "gyro_y_dps",
    "gyro_z_dps",
    "heart_rate_bpm",
    "hrv_rr_ms",
    "pressure_pa",
    "flow_l_s",
    "breath_number",
    "breath_vol_l",
    "ve_l_min",
    "o2_pct",
    "co2_pct",
    "vo2_ml_kg_min",
    "vo2_roll_ml_kg_min",
    "vo2_roll_max_ml_kg_min",
    "kcal_total",
)


def iso_timestamp(wall_time_s: float) -> str:
    return datetime.fromtimestamp(wall_time_s).isoformat(timespec="milliseconds")


def _csv_cell(value) -> str:
    if value is None:
        return ""
    return str(value)


def _session_elapsed(wall_time_s: float, recording_start_wall_s: float) -> Optional[float]:
    session_elapsed_s = wall_time_s - recording_start_wall_s
    if session_elapsed_s < 0:
        return None
    return session_elapsed_s


@dataclass(frozen=True)
class Vo2RecordRow:
    wall_time_s: float
    t_s: float
    sample_idx: int
    pressure_pa: float
    flow_l_s: float
    breath_number: Optional[int]
    breath_vol_l: Optional[float]
    ve_l_min: float
    o2_pct: Optional[float]
    co2_pct: Optional[float]
    vo2_ml_kg_min: Optional[float]
    vo2_roll_ml_kg_min: Optional[float]
    vo2_roll_max_ml_kg_min: float
    kcal_total: float


@dataclass(frozen=True)
class PulseBandRecordRow:
    wall_time_s: float
    elapsed_s: float
    event_type: str
    ecg_heart_adc: Optional[int]
    ecg_breath_adc: Optional[int]
    accel_x_g: Optional[float]
    accel_y_g: Optional[float]
    accel_z_g: Optional[float]
    gyro_x_dps: Optional[float]
    gyro_y_dps: Optional[float]
    gyro_z_dps: Optional[float]
    imu_sample_idx: Optional[int]
    heart_rate_bpm: Optional[int]
    hrv_rr_ms: Optional[int]
    seq: int
    pulse_sample_idx: Optional[int] = None


@dataclass
class AlignedCsvFrame:
    mask_t_s: Optional[float] = None
    pulse_elapsed_s: Optional[float] = None
    mask_sample_idx: Optional[int] = None
    imu_sample_idx: Optional[int] = None
    ecg_heart_adc: Optional[int] = None
    ecg_breath_adc: Optional[int] = None
    accel_x_g: Optional[float] = None
    accel_y_g: Optional[float] = None
    accel_z_g: Optional[float] = None
    gyro_x_dps: Optional[float] = None
    gyro_y_dps: Optional[float] = None
    gyro_z_dps: Optional[float] = None
    heart_rate_bpm: Optional[int] = None
    hrv_rr_ms: Optional[int] = None
    pressure_pa: Optional[float] = None
    flow_l_s: Optional[float] = None
    breath_number: Optional[int] = None
    breath_vol_l: Optional[float] = None
    ve_l_min: Optional[float] = None
    o2_pct: Optional[float] = None
    co2_pct: Optional[float] = None
    vo2_ml_kg_min: Optional[float] = None
    vo2_roll_ml_kg_min: Optional[float] = None
    vo2_roll_max_ml_kg_min: Optional[float] = None
    kcal_total: Optional[float] = None

    def apply_vo2(self, row: Vo2RecordRow) -> None:
        self.mask_t_s = row.t_s
        self.mask_sample_idx = row.sample_idx
        self.pressure_pa = row.pressure_pa
        self.flow_l_s = row.flow_l_s
        self.breath_number = row.breath_number
        self.breath_vol_l = row.breath_vol_l
        self.ve_l_min = row.ve_l_min
        self.o2_pct = row.o2_pct
        self.co2_pct = row.co2_pct
        self.vo2_ml_kg_min = row.vo2_ml_kg_min
        self.vo2_roll_ml_kg_min = row.vo2_roll_ml_kg_min
        self.vo2_roll_max_ml_kg_min = row.vo2_roll_max_ml_kg_min
        self.kcal_total = row.kcal_total

    def apply_pulse(self, row: PulseBandRecordRow) -> None:
        self.pulse_elapsed_s = row.elapsed_s
        if row.event_type in ("pulse_ecg", "pulse_breath"):
            if row.ecg_heart_adc is not None:
                self.ecg_heart_adc = row.ecg_heart_adc
            if row.ecg_breath_adc is not None:
                self.ecg_breath_adc = row.ecg_breath_adc
        elif row.event_type == "pulse_imu":
            self.imu_sample_idx = row.imu_sample_idx
            self.accel_x_g = row.accel_x_g
            self.accel_y_g = row.accel_y_g
            self.accel_z_g = row.accel_z_g
            self.gyro_x_dps = row.gyro_x_dps
            self.gyro_y_dps = row.gyro_y_dps
            self.gyro_z_dps = row.gyro_z_dps
        elif row.event_type == "pulse_hr":
            self.heart_rate_bpm = row.heart_rate_bpm
        elif row.event_type == "pulse_hrv":
            self.hrv_rr_ms = row.hrv_rr_ms


class MaskWallClockAligner:
    def __init__(self) -> None:
        self.wall_anchor_s: Optional[float] = None

    def observe_point(self, device_t_s: float, packet_wall_time_s: float) -> None:
        if self.wall_anchor_s is None:
            self.wall_anchor_s = packet_wall_time_s - device_t_s

    def wall_time(self, device_t_s: float) -> Optional[float]:
        if self.wall_anchor_s is None:
            return None
        return self.wall_anchor_s + device_t_s


def is_post_start_sample(wall_time_s: float, recording_start_wall_s: float) -> bool:
    return _session_elapsed(wall_time_s, recording_start_wall_s) is not None


def frame_index_for_elapsed(elapsed_s: float, sample_rate_hz: float) -> int:
    rate_hz = max(1.0, sample_rate_hz)
    return int(math.floor((max(0.0, elapsed_s) * rate_hz) + 0.5))


@dataclass
class LatchedHrValues:
    heart_rate_bpm: Optional[int] = None
    hrv_rr_ms: Optional[int] = None


def render_aligned_frame(
    frame_idx: int,
    grid_start_wall_s: float,
    sample_rate_hz: float,
    frame: Optional[AlignedCsvFrame],
    latched_hr: LatchedHrValues,
) -> list[str]:
    rate_hz = max(1.0, sample_rate_hz)
    session_elapsed_s = frame_idx / rate_hz
    if frame is not None:
        if frame.heart_rate_bpm is not None:
            latched_hr.heart_rate_bpm = frame.heart_rate_bpm
        if frame.hrv_rr_ms is not None:
            latched_hr.hrv_rr_ms = frame.hrv_rr_ms
    wall_time_s = grid_start_wall_s + session_elapsed_s
    return [
        iso_timestamp(wall_time_s),
        _csv_cell(session_elapsed_s),
        _csv_cell(frame.mask_t_s if frame else None),
        _csv_cell(frame.pulse_elapsed_s if frame else None),
        _csv_cell(frame.mask_sample_idx if frame else None),
        _csv_cell(frame.imu_sample_idx if frame else None),
        _csv_cell(frame.ecg_heart_adc if frame else None),
        _csv_cell(frame.ecg_breath_adc if frame else None),
        _csv_cell(frame.accel_x_g if frame else None),
        _csv_cell(frame.accel_y_g if frame else None),
        _csv_cell(frame.accel_z_g if frame else None),
        _csv_cell(frame.gyro_x_dps if frame else None),
        _csv_cell(frame.gyro_y_dps if frame else None),
        _csv_cell(frame.gyro_z_dps if frame else None),
        _csv_cell(latched_hr.heart_rate_bpm),
        _csv_cell(latched_hr.hrv_rr_ms),
        _csv_cell(frame.pressure_pa if frame else None),
        _csv_cell(frame.flow_l_s if frame else None),
        _csv_cell(frame.breath_number if frame else None),
        _csv_cell(frame.breath_vol_l if frame else None),
        _csv_cell(frame.ve_l_min if frame else None),
        _csv_cell(frame.o2_pct if frame else None),
        _csv_cell(frame.co2_pct if frame else None),
        _csv_cell(frame.vo2_ml_kg_min if frame else None),
        _csv_cell(frame.vo2_roll_ml_kg_min if frame else None),
        _csv_cell(frame.vo2_roll_max_ml_kg_min if frame else None),
        _csv_cell(frame.kcal_total if frame else None),
    ]


def resolve_recording_output_path(
    path_arg: Optional[str],
    legacy_path_arg: Optional[str],
    default_dir: Path,
    *,
    now: Optional[datetime] = None,
) -> Path:
    stamp = (now or datetime.now()).strftime("%Y%m%d_%H%M%S")
    chosen = path_arg or legacy_path_arg
    if not chosen:
        return default_dir / f"session_recording_{stamp}.csv"
    output = Path(chosen).expanduser()
    if output.exists() and output.is_dir():
        return output / f"session_recording_{stamp}.csv"
    return output
