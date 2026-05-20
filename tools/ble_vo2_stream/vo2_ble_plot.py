#!/usr/bin/env python3
"""BLE receiver + live plotter for SpiroVO2-RAW packets."""

from __future__ import annotations

import argparse
import asyncio
import csv
import struct
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from queue import Queue, Empty
from typing import Optional

try:
    from bleak import BleakClient, BleakScanner
except ImportError as exc:
    print("bleak is required. Install with: pip install bleak", file=sys.stderr)
    raise

try:
    import numpy as np
    from qt_compat import QtCore, QtGui, QtWidgets, exec_app, exec_dialog, pg
except ImportError as exc:
    print(
        "pyqtgraph + numpy + a supported Qt binding are required. "
        "Install with: pip install pyqtgraph numpy PySide6 (Windows) "
        "or PyQt5 (macOS/Linux)",
        file=sys.stderr,
    )
    raise

SERVICE_UUID = "7a1b7d30-2e4b-4b2f-8f1a-2dfe3e5c0e11"
STREAM_CHAR_UUID = "7a1b7d31-2e4b-4b2f-8f1a-2dfe3e5c0e11"

PKT_CONFIG = 0x01
PKT_PRESSURE = 0x02
PKT_O2 = 0x03
PKT_CO2 = 0x04
PKT_BATTERY = 0x05
PKT_TEMP = 0x06

FI_CO2 = 0.04
VT_SHORT_WINDOW_S = 30.0
VT_LONG_WINDOW_S = 180.0
VT_INCREASE_DELTA = 2.0


@dataclass
class StreamConfig:
    sample_rate_hz: float = 200.0
    area_1: float = 0.000531
    area_2: float = 0.000201
    correction: float = 0.92
    temp_c: float = 15.0
    pres_pa: float = 101325.0
    fi_o2: float = 20.90
    pressure_scale: float = 10.0
    pressure_sign: int = 1


class BleWorker(threading.Thread):
    def __init__(self, name: str, queue: Queue, status_cb, scan_interval: float = 2.0):
        super().__init__(daemon=True)
        self.device_name = name
        self.queue = queue
        self._stop = threading.Event()
        self._status_cb = status_cb
        self._scan_interval = scan_interval

    def stop(self):
        self._stop.set()

    def run(self):
        asyncio.run(self._run())

    async def _run(self):
        while not self._stop.is_set():
            self._status_cb(f"Scanning for {self.device_name}...")
            device = await BleakScanner.find_device_by_filter(
                lambda d, ad: d.name == self.device_name,
                timeout=5.0,
            )
            if self._stop.is_set():
                break
            if not device:
                self._status_cb("Device not found. Retrying...")
                await asyncio.sleep(self._scan_interval)
                continue

            try:
                async with BleakClient(device) as client:
                    self._status_cb("Connected. Streaming...")

                    def handle_notify(_, data: bytearray):
                        if not data:
                            return
                        self.queue.put(bytes(data))

                    await client.start_notify(STREAM_CHAR_UUID, handle_notify)

                    while not self._stop.is_set() and client.is_connected:
                        await asyncio.sleep(0.2)

                    try:
                        await client.stop_notify(STREAM_CHAR_UUID)
                    except Exception:
                        pass
                    try:
                        await client.disconnect()
                    except Exception:
                        pass
            except Exception as exc:
                self._status_cb(f"BLE error: {exc}. Retrying...")
                await asyncio.sleep(self._scan_interval)
                continue

            if not self._stop.is_set():
                self._status_cb("Disconnected. Retrying...")
                await asyncio.sleep(self._scan_interval)
        self._status_cb("Stopped.")


class Vo2Processor:
    def __init__(
        self,
        weight_kg: float,
        vo2_window_sec: float,
        pressure_deadband_pa: float,
        flow_start_l_s: float,
        flow_end_l_s: float,
        min_breath_l: float,
        min_breath_s: float,
        start_hold_s: float,
        end_hold_s: float,
    ):
        self.weight_kg = weight_kg
        self.vo2_window_sec = vo2_window_sec
        self.pressure_deadband_pa = pressure_deadband_pa
        self.flow_start_l_s = flow_start_l_s
        self.flow_end_l_s = flow_end_l_s
        self.min_breath_l = min_breath_l
        self.min_breath_s = min_breath_s
        self.start_hold_s = start_hold_s
        self.end_hold_s = end_hold_s
        self.config = StreamConfig()
        self._config_seen = False
        self._sample_t0 = None

        self._default_maxlens = {
            "pressure_times": 4000,
            "pressure_vals": 4000,
            "breath_times": 600,
            "breath_vols": 600,
            "vo2_times": 600,
            "vo2_vals": 600,
            "o2_times": 600,
            "o2_vals": 600,
            "co2_times": 600,
            "co2_vals": 600,
            "ve_times": 600,
            "ve_vals": 600,
            "ve_vo2_times": 600,
            "ve_vo2_vals": 600,
            "ve_vco2_times": 600,
            "ve_vco2_vals": 600,
            "temp_times": 600,
            "temp_vals": 600,
        }
        self._graph_buffers = {
            "pressure": ("pressure_times", "pressure_vals"),
            "breath": ("breath_times", "breath_vols"),
            "gas": ("o2_times", "o2_vals", "co2_times", "co2_vals"),
            "vo2": ("vo2_times", "vo2_vals"),
            "ve": ("ve_times", "ve_vals"),
            "ve_vo2": ("ve_vo2_times", "ve_vo2_vals"),
            "ve_vco2": ("ve_vco2_times", "ve_vco2_vals"),
            "temp": ("temp_times", "temp_vals"),
        }

        self.pressure_times = deque(maxlen=self._default_maxlens["pressure_times"])
        self.pressure_vals = deque(maxlen=self._default_maxlens["pressure_vals"])

        self.breath_times = deque(maxlen=self._default_maxlens["breath_times"])
        self.breath_vols = deque(maxlen=self._default_maxlens["breath_vols"])

        self.vo2_times = deque(maxlen=self._default_maxlens["vo2_times"])
        self.vo2_vals = deque(maxlen=self._default_maxlens["vo2_vals"])

        self.o2_times = deque(maxlen=self._default_maxlens["o2_times"])
        self.o2_vals = deque(maxlen=self._default_maxlens["o2_vals"])
        self.co2_times = deque(maxlen=self._default_maxlens["co2_times"])
        self.co2_vals = deque(maxlen=self._default_maxlens["co2_vals"])
        self.ve_times = deque(maxlen=self._default_maxlens["ve_times"])
        self.ve_vals = deque(maxlen=self._default_maxlens["ve_vals"])
        self.ve_vo2_times = deque(maxlen=self._default_maxlens["ve_vo2_times"])
        self.ve_vo2_vals = deque(maxlen=self._default_maxlens["ve_vo2_vals"])
        self.ve_vco2_times = deque(maxlen=self._default_maxlens["ve_vco2_times"])
        self.ve_vco2_vals = deque(maxlen=self._default_maxlens["ve_vco2_vals"])
        self.temp_times = deque(maxlen=self._default_maxlens["temp_times"])
        self.temp_vals = deque(maxlen=self._default_maxlens["temp_vals"])

        self._last_o2 = None
        self._last_co2 = None
        self._last_temp = None
        self._last_ve = None
        self._last_vo2_total = None
        self._last_vco2_total = None
        self._ve_mean = 0.0
        self._vo2_roll_max = 0.0
        self._kcal_total = 0.0
        self._last_vo2_time = None
        self._last_vo2_value = None
        self._last_vo2_roll = None
        self._vo2_window = deque()
        self._record_samples = []
        self._battery_percent = None
        self._battery_time = None
        self._vt_status = None

        self._breath_active = False
        self._breath_start_t = None
        self._breath_vol_ml = 0.0
        self._last_sample_time = None
        self._start_count = 0
        self._end_count = 0
        self._max_breath_s = 10.0

    def reset(self) -> None:
        self.pressure_times.clear()
        self.pressure_vals.clear()
        self.breath_times.clear()
        self.breath_vols.clear()
        self.vo2_times.clear()
        self.vo2_vals.clear()
        self.o2_times.clear()
        self.o2_vals.clear()
        self.co2_times.clear()
        self.co2_vals.clear()
        self.ve_times.clear()
        self.ve_vals.clear()
        self.ve_vo2_times.clear()
        self.ve_vo2_vals.clear()
        self.ve_vco2_times.clear()
        self.ve_vco2_vals.clear()
        self.temp_times.clear()
        self.temp_vals.clear()
        self._last_o2 = None
        self._last_co2 = None
        self._last_temp = None
        self._last_ve = None
        self._last_vo2_total = None
        self._last_vco2_total = None
        self._ve_mean = 0.0
        self._vo2_roll_max = 0.0
        self._kcal_total = 0.0
        self._last_vo2_time = None
        self._last_vo2_value = None
        self._last_vo2_roll = None
        self._vo2_window.clear()
        self._record_samples = []
        self._battery_percent = None
        self._battery_time = None
        self._vt_status = None
        self._breath_active = False
        self._breath_start_t = None
        self._breath_vol_ml = 0.0
        self._last_sample_time = None
        self._start_count = 0
        self._end_count = 0

    def set_weight_kg(self, weight_kg: float) -> None:
        if weight_kg <= 0:
            return
        self.weight_kg = weight_kg

    def set_graph_unlimited(self, key: str, unlimited: bool) -> None:
        attrs = self._graph_buffers.get(key)
        if not attrs:
            return
        for attr in attrs:
            old = getattr(self, attr)
            items = list(old)
            maxlen = None if unlimited else self._default_maxlens.get(attr)
            setattr(self, attr, deque(items, maxlen=maxlen))

    def _decode_co2_pct(self, raw_x100: int) -> float:
        # Raw can be percent*100 or ppm. Convert to percent and clamp to valid range.
        if raw_x100 > 2500:  # >25.00% is out of STC31 range; assume ppm
            co2_pct = raw_x100 / 10000.0
        else:
            co2_pct = raw_x100 / 100.0
        if co2_pct < 0.0:
            co2_pct = 0.0
        elif co2_pct > 25.0:
            co2_pct = 25.0
        return co2_pct

    def update_config(self, payload: bytes) -> None:
        if len(payload) < 1 + 1 + (8 * 4) + 1:
            return
        _, version = payload[0], payload[1]
        if version != 1:
            return
        floats = struct.unpack_from("<8f", payload, 2)
        self.config = StreamConfig(
            sample_rate_hz=floats[0],
            area_1=floats[1],
            area_2=floats[2],
            correction=floats[3],
            temp_c=floats[4],
            pres_pa=floats[5],
            fi_o2=floats[6],
            pressure_scale=floats[7],
            pressure_sign=struct.unpack_from("<b", payload, 2 + 8 * 4)[0],
        )
        self._config_seen = True

    def update_o2(self, payload: bytes) -> None:
        if len(payload) < 1 + 4 + 2:
            return
        _, time_ms, o2_x100 = struct.unpack_from("<BIH", payload, 0)
        self._last_o2 = o2_x100 / 100.0
        t = time_ms / 1000.0
        self.o2_times.append(t)
        self.o2_vals.append(self._last_o2)

    def update_co2(self, payload: bytes) -> None:
        if len(payload) < 1 + 4 + 2:
            return
        _, time_ms, co2_x100 = struct.unpack_from("<BIH", payload, 0)
        self._last_co2 = self._decode_co2_pct(co2_x100)
        t = time_ms / 1000.0
        self.co2_times.append(t)
        self.co2_vals.append(self._last_co2)

    def update_battery(self, payload: bytes) -> None:
        if len(payload) < 1 + 4 + 1:
            return
        _, time_ms, percent = struct.unpack_from("<BIB", payload, 0)
        self._battery_percent = int(percent)
        self._battery_time = time_ms / 1000.0

    def update_temp(self, payload: bytes) -> None:
        if len(payload) < 1 + 4 + 2:
            return
        _, time_ms, temp_x100 = struct.unpack_from("<BIh", payload, 0)
        self._last_temp = temp_x100 / 100.0
        t = time_ms / 1000.0
        self.temp_times.append(t)
        self.temp_vals.append(self._last_temp)

    def _calc_flow_l_s(self, pressure_pa: float) -> float:
        cfg = self.config
        temp_c = self._last_temp if self._last_temp is not None else cfg.temp_c
        rho = cfg.pres_pa / (temp_c + 273.15) / 287.058
        denom = (1.0 / (cfg.area_2 ** 2)) - (1.0 / (cfg.area_1 ** 2))
        if denom <= 0:
            return 0.0
        mass_flow = 1000.0 * ((abs(pressure_pa) * 2.0 * rho) / denom) ** 0.5
        vol_flow = (mass_flow / rho) * cfg.correction
        return vol_flow

    def _update_vo2(self, ve_l_min: float) -> None:
        if self._last_o2 is None:
            return
        cfg = self.config
        o2_diff = max(0.0, cfg.fi_o2 - self._last_o2)
        rho_bpts = cfg.pres_pa / (35.0 + 273.15) / 292.9
        rho_stpd = 1.292
        vo2_total = ve_l_min * (rho_bpts / rho_stpd) * o2_diff * 10.0
        vo2_max = vo2_total / max(1e-6, self.weight_kg)
        t = self._last_sample_time if self._last_sample_time else 0.0
        self._last_vo2_total = vo2_total
        self.vo2_times.append(t)
        self.vo2_vals.append(vo2_max)
        self._last_vo2_value = vo2_max
        self._vo2_window.append((t, vo2_max))
        while self._vo2_window and (t - self._vo2_window[0][0]) > self.vo2_window_sec:
            self._vo2_window.popleft()
        if self._vo2_window:
            avg = sum(v for _, v in self._vo2_window) / len(self._vo2_window)
            self._last_vo2_roll = avg
            if avg > self._vo2_roll_max:
                self._vo2_roll_max = avg
        if self._last_vo2_time is not None:
            dt_min = max(0.0, t - self._last_vo2_time) / 60.0
            kcal_per_min = (vo2_total / 1000.0) * 5.0
            self._kcal_total += kcal_per_min * dt_min
        self._last_vo2_time = t

        if vo2_total > 0.0:
            ve_vo2 = ve_l_min / (vo2_total / 1000.0)
            self.ve_vo2_times.append(t)
            self.ve_vo2_vals.append(ve_vo2)

        if self._last_co2 is not None:
            co2_diff = max(0.0, self._last_co2 - FI_CO2)
            vco2_total = ve_l_min * (rho_bpts / rho_stpd) * co2_diff * 10.0
            self._last_vco2_total = vco2_total
            if vco2_total > 0.0:
                ve_vco2 = ve_l_min / (vco2_total / 1000.0)
                self.ve_vco2_times.append(t)
                self.ve_vco2_vals.append(ve_vco2)

        self._update_vt_status()

    def _finish_breath(self, t: float, force: bool = False) -> None:
        vol_l = self._breath_vol_ml / 1000.0
        if self._breath_start_t is not None:
            dur = max(1e-3, t - self._breath_start_t)
            if force or (vol_l >= self.min_breath_l and dur >= self.min_breath_s):
                self.breath_times.append(t)
                self.breath_vols.append(vol_l)
                ve = (vol_l / dur) * 60.0
                self._ve_mean = (self._ve_mean * 0.75) + (ve * 0.25)
                self._last_ve = self._ve_mean
                self.ve_times.append(t)
                self.ve_vals.append(self._ve_mean)
                self._update_vo2(self._ve_mean)
        self._breath_vol_ml = 0.0
        self._breath_active = False
        self._start_count = 0
        self._end_count = 0

    def _window_avg(self, times, values, window_s: float, min_samples: int = 5):
        if not times:
            return None
        t_end = times[-1]
        t_start = t_end - window_s
        total = 0.0
        count = 0
        for t, v in zip(reversed(times), reversed(values)):
            if t < t_start:
                break
            if v is None or not np.isfinite(v):
                continue
            total += v
            count += 1
        if count < min_samples:
            return None
        return total / count

    def _update_vt_status(self) -> None:
        vo2_short = self._window_avg(self.ve_vo2_times, self.ve_vo2_vals, VT_SHORT_WINDOW_S)
        vo2_long = self._window_avg(self.ve_vo2_times, self.ve_vo2_vals, VT_LONG_WINDOW_S)
        vco2_short = self._window_avg(
            self.ve_vco2_times, self.ve_vco2_vals, VT_SHORT_WINDOW_S
        )
        vco2_long = self._window_avg(
            self.ve_vco2_times, self.ve_vco2_vals, VT_LONG_WINDOW_S
        )
        if None in (vo2_short, vo2_long, vco2_short, vco2_long):
            self._vt_status = None
            return
        inc_vo2 = (vo2_short - vo2_long) >= VT_INCREASE_DELTA
        inc_vco2 = (vco2_short - vco2_long) >= VT_INCREASE_DELTA
        if inc_vo2 and inc_vco2:
            self._vt_status = "Above VT2"
        elif inc_vo2:
            self._vt_status = "Between VT1 and VT2"
        else:
            self._vt_status = "Below VT1"

    def update_pressure(self, payload: bytes) -> None:
        if len(payload) < 1 + 4 + 2:
            return
        _, start_idx, count = struct.unpack_from("<BIH", payload, 0)
        expected_len = 1 + 4 + 2 + (count * 2)
        if len(payload) < expected_len:
            return
        samples = struct.unpack_from("<" + "h" * count, payload, 7)

        if self._sample_t0 is None:
            self._sample_t0 = time.monotonic()

        cfg = self.config
        cfg = self.config
        sr = max(1.0, cfg.sample_rate_hz)
        start_hold_samples = max(1, int(self.start_hold_s * sr))
        end_hold_samples = max(1, int(self.end_hold_s * sr))

        for i, raw in enumerate(samples):
            pressure_pa_raw = (raw / cfg.pressure_scale) * cfg.pressure_sign
            pressure_pa = pressure_pa_raw
            sample_idx = start_idx + i
            t = sample_idx / cfg.sample_rate_hz
            self._last_sample_time = t
            self.pressure_times.append(t)
            self.pressure_vals.append(pressure_pa)

            if abs(pressure_pa) < self.pressure_deadband_pa:
                flow_l_s = 0.0
            else:
                flow_l_s = self._calc_flow_l_s(pressure_pa)
            dt = 1.0 / cfg.sample_rate_hz
            if not self._breath_active:
                if flow_l_s >= self.flow_start_l_s:
                    self._start_count += 1
                    if self._start_count >= start_hold_samples:
                        self._breath_active = True
                        self._breath_start_t = t
                        self._breath_vol_ml = 0.0
                        self._end_count = 0
                else:
                    self._start_count = 0
            else:
                if flow_l_s >= self.flow_end_l_s:
                    self._end_count = 0
                else:
                    self._end_count += 1
                    if self._end_count >= end_hold_samples:
                        self._finish_breath(t)

                if (
                    self._breath_start_t is not None
                    and (t - self._breath_start_t) >= self._max_breath_s
                ):
                    self._finish_breath(t, force=True)

            if self._breath_active and flow_l_s > 0.0:
                self._breath_vol_ml += flow_l_s * dt * 1000.0

            breath_vol_l = self._breath_vol_ml / 1000.0

            self._record_samples.append(
                (
                    t,
                    sample_idx,
                    pressure_pa,
                    flow_l_s,
                    breath_vol_l,
                    self._ve_mean,
                    self._last_o2,
                    self._last_co2,
                    self._last_vo2_value,
                    self._last_vo2_roll,
                    self._vo2_roll_max,
                    self._kcal_total,
                    self._last_temp,
                )
            )

    def handle_packet(self, payload: bytes) -> None:
        if not payload:
            return
        pkt_type = payload[0]
        if pkt_type == PKT_CONFIG:
            self.update_config(payload)
        elif pkt_type == PKT_PRESSURE:
            self.update_pressure(payload)
        elif pkt_type == PKT_O2:
            self.update_o2(payload)
        elif pkt_type == PKT_CO2:
            self.update_co2(payload)
        elif pkt_type == PKT_BATTERY:
            self.update_battery(payload)
        elif pkt_type == PKT_TEMP:
            self.update_temp(payload)

    def pop_record_samples(self):
        if not self._record_samples:
            return []
        items = self._record_samples
        self._record_samples = []
        return items

    @property
    def vo2_max(self) -> float:
        return self._vo2_roll_max

    @property
    def kcal_total(self) -> float:
        return self._kcal_total

    @property
    def vo2_roll(self) -> Optional[float]:
        return self._last_vo2_roll

    @property
    def ve_latest(self) -> Optional[float]:
        return self._last_ve

    @property
    def battery_percent(self) -> Optional[int]:
        return self._battery_percent

    @property
    def vt_status(self) -> Optional[str]:
        return self._vt_status


class TimeAxisItem(pg.AxisItem):
    def __init__(self, *args, base_time: Optional[float] = None, **kwargs):
        super().__init__(*args, **kwargs)
        self._base_time = base_time if base_time is not None else time.time()

    def set_base_time(self, base_time: float) -> None:
        self._base_time = base_time

    def tickStrings(self, values, scale, spacing):
        labels = []
        for v in values:
            if not np.isfinite(v):
                labels.append("")
                continue
            ts = self._base_time + v
            labels.append(datetime.fromtimestamp(ts).strftime("%H:%M:%S"))
        return labels


class Recorder:
    def __init__(self, base_dir: Path):
        self.base_dir = base_dir
        self.file = None
        self.writer = None
        self.path = None

    def start(self, config: StreamConfig) -> Path:
        self.base_dir.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.path = self.base_dir / f"vo2_recording_{timestamp}.csv"
        self.file = self.path.open("w", newline="")
        self.writer = csv.writer(self.file)
        # Config summary as commented lines
        self.file.write("# SpiroVO2 recording\n")
        self.file.write(
            f"# sample_rate_hz={config.sample_rate_hz},"
            f" area_1={config.area_1}, area_2={config.area_2},"
            f" correction={config.correction}, temp_c={config.temp_c},"
            f" pres_pa={config.pres_pa}, fi_o2={config.fi_o2},"
            f" pressure_scale={config.pressure_scale}, pressure_sign={config.pressure_sign}\n"
        )
        self.writer.writerow(
            [
                "t_s",
                "sample_idx",
                "pressure_pa",
                "flow_l_s",
                "breath_vol_l",
                "ve_l_min",
                "o2_pct",
                "co2_pct",
                "vo2_ml_kg_min",
                "vo2_roll_ml_kg_min",
                "vo2_roll_max_ml_kg_min",
                "kcal_total",
                "temp_c",
            ]
        )
        self.file.flush()
        return self.path

    def stop(self) -> None:
        if self.file:
            self.file.flush()
            self.file.close()
        self.file = None
        self.writer = None
        self.path = None

    def is_recording(self) -> bool:
        return self.writer is not None

    def write_samples(self, samples) -> None:
        if not self.writer or not samples:
            return
        for row in samples:
            self.writer.writerow(row)
        self.file.flush()


class PlotWindow(QtWidgets.QWidget):
    def __init__(
        self,
        processor: Vo2Processor,
        recorder: Recorder,
        status_cb,
        load_weight_from_settings: bool = True,
    ):
        super().__init__()
        self.processor = processor
        self.recorder = recorder
        self._status_cb = status_cb
        self._on_close = None
        self._connected = False
        self._settings = QtCore.QSettings()
        self._load_weight_from_settings = load_weight_from_settings
        self._build_ui()
        self._load_settings()

    def _build_ui(self):
        self.setWindowTitle("VO2 BLE Stream")
        layout = QtWidgets.QVBoxLayout(self)
        self._base_time = time.time()
        self._time_axes = []

        def time_axis() -> TimeAxisItem:
            axis = TimeAxisItem(orientation="bottom", base_time=self._base_time)
            self._time_axes.append(axis)
            return axis

        self.status_label = QtWidgets.QLabel("Waiting for data...")
        layout.addWidget(self.status_label)

        stats = QtWidgets.QHBoxLayout()
        self.vo2max_label = QtWidgets.QLabel("VO2Max (15s avg): --")
        self.kcal_label = QtWidgets.QLabel("kcal: --")
        stats.addWidget(self.vo2max_label)
        stats.addStretch(1)
        stats.addWidget(self.kcal_label)
        layout.addLayout(stats)

        stats2 = QtWidgets.QHBoxLayout()
        self.ve_label = QtWidgets.QLabel("VE: -- L/min")
        self.vt_label = QtWidgets.QLabel("VT: --")
        self.temp_label = QtWidgets.QLabel("Temp: --")
        self.battery_label = QtWidgets.QLabel("Battery: --")
        stats2.addWidget(self.ve_label)
        stats2.addStretch(1)
        stats2.addWidget(self.vt_label)
        stats2.addStretch(1)
        stats2.addWidget(self.temp_label)
        stats2.addStretch(1)
        stats2.addWidget(self.battery_label)
        layout.addLayout(stats2)

        controls = QtWidgets.QHBoxLayout()
        self.record_button = QtWidgets.QPushButton("Start Recording")
        self.record_button.clicked.connect(self.toggle_recording)
        controls.addWidget(self.record_button)

        self.settings_button = QtWidgets.QPushButton("Settings")
        self.settings_button.clicked.connect(self.open_settings)
        controls.addWidget(self.settings_button)

        controls.addStretch(1)
        layout.addLayout(controls)

        self.graph_sections = {}
        self.graph_visibility = {}
        self.graph_time_windows = {}
        self.graph_options = [
            ("pressure", "Pressure", 20),
            ("breath", "Breath Volume", 20),
            ("gas", "O2 / CO2", 120),
            ("vo2", "VO2", 120),
            ("ve", "Minute Ventilation", 120),
            ("ve_vo2", "VE / VO2", 120),
            ("ve_vco2", "VE / VCO2", 120),
            ("temp", "Temperature", 120),
        ]
        self.graph_time_windows = {
            key: window for key, _, window in self.graph_options
        }

        def add_section(key: str, widget: QtWidgets.QWidget, extra_layout=None) -> None:
            section = QtWidgets.QWidget()
            section_layout = QtWidgets.QVBoxLayout(section)
            section_layout.setContentsMargins(0, 0, 0, 0)
            section_layout.setSpacing(4)
            section_layout.addWidget(widget)
            if extra_layout is not None:
                section_layout.addLayout(extra_layout)
            section.setSizePolicy(
                QtWidgets.QSizePolicy.Expanding, QtWidgets.QSizePolicy.Expanding
            )
            layout.addWidget(section, stretch=1)
            self.graph_sections[key] = section
            self.graph_visibility[key] = True

        self.pressure_plot = pg.PlotWidget(
            title="Pressure (Pa)",
            axisItems={"bottom": time_axis()},
        )
        self.pressure_plot.showGrid(x=True, y=True, alpha=0.3)
        self.pressure_curve = self.pressure_plot.plot(pen=pg.mkPen("#40c4ff", width=2))
        add_section("pressure", self.pressure_plot)

        self.breath_plot = pg.PlotWidget(
            title="Breath Volume (L)",
            axisItems={"bottom": time_axis()},
        )
        self.breath_plot.showGrid(x=True, y=True, alpha=0.3)
        self.breath_scatter = pg.ScatterPlotItem(size=8, brush=pg.mkBrush("#ffab40"))
        self.breath_plot.addItem(self.breath_scatter)
        add_section("breath", self.breath_plot)

        self.gas_plot = pg.PlotWidget(
            title="O2 / CO2 (%)",
            axisItems={"bottom": time_axis()},
        )
        self.gas_plot.showGrid(x=True, y=True, alpha=0.3)
        self.o2_curve = self.gas_plot.plot(pen=pg.mkPen("#00e676", width=2), name="O2")
        self.co2_curve = self.gas_plot.plot(pen=pg.mkPen("#ff5252", width=2), name="CO2")
        self.gas_plot.addLegend()
        gas_legend = QtWidgets.QHBoxLayout()
        gas_legend.addWidget(self._legend_item("#00e676", "O2"))
        gas_legend.addWidget(self._legend_item("#ff5252", "CO2"))
        gas_legend.addStretch(1)
        add_section("gas", self.gas_plot, gas_legend)

        self.vo2_plot = pg.PlotWidget(
            title="VO2 (ml/kg/min)",
            axisItems={"bottom": time_axis()},
        )
        self.vo2_plot.showGrid(x=True, y=True, alpha=0.3)
        self.vo2_curve = self.vo2_plot.plot(pen=pg.mkPen("#cddc39", width=2))
        add_section("vo2", self.vo2_plot)

        self.ve_plot = pg.PlotWidget(
            title="Minute Ventilation (L/min)",
            axisItems={"bottom": time_axis()},
        )
        self.ve_plot.showGrid(x=True, y=True, alpha=0.3)
        self.ve_curve = self.ve_plot.plot(pen=pg.mkPen("#ff6f00", width=2))
        add_section("ve", self.ve_plot)

        self.ve_vo2_plot = pg.PlotWidget(
            title="VE / VO2",
            axisItems={"bottom": time_axis()},
        )
        self.ve_vo2_plot.showGrid(x=True, y=True, alpha=0.3)
        self.ve_vo2_curve = self.ve_vo2_plot.plot(pen=pg.mkPen("#ff8a65", width=2))
        add_section("ve_vo2", self.ve_vo2_plot)

        self.ve_vco2_plot = pg.PlotWidget(
            title="VE / VCO2",
            axisItems={"bottom": time_axis()},
        )
        self.ve_vco2_plot.showGrid(x=True, y=True, alpha=0.3)
        self.ve_vco2_curve = self.ve_vco2_plot.plot(pen=pg.mkPen("#8d6e63", width=2))
        add_section("ve_vco2", self.ve_vco2_plot)

        self.temp_plot = pg.PlotWidget(
            title="Temperature (\u00b0C)",
            axisItems={"bottom": time_axis()},
        )
        self.temp_plot.showGrid(x=True, y=True, alpha=0.3)
        self.temp_curve = self.temp_plot.plot(pen=pg.mkPen("#e040fb", width=2))
        add_section("temp", self.temp_plot)

        self.apply_theme("Dark")

    def _legend_item(self, color: str, text: str) -> QtWidgets.QWidget:
        widget = QtWidgets.QWidget()
        row = QtWidgets.QHBoxLayout(widget)
        row.setContentsMargins(0, 0, 0, 0)
        swatch = QtWidgets.QLabel()
        swatch.setFixedSize(10, 10)
        swatch.setStyleSheet(f"background-color: {color}; border-radius: 5px;")
        label = QtWidgets.QLabel(text)
        row.addWidget(swatch)
        row.addWidget(label)
        return widget

    def _set_graph_visibility(self, key: str, visible: bool) -> None:
        section = self.graph_sections.get(key)
        if section is not None:
            section.setVisible(visible)
        self.graph_visibility[key] = visible

    def _load_settings(self) -> None:
        settings = self._settings
        theme = settings.value("ui/theme", "Dark")
        self.apply_theme(theme)
        if self._load_weight_from_settings:
            weight_val = settings.value("user/weight_kg")
            if weight_val is not None:
                try:
                    self.processor.set_weight_kg(float(weight_val))
                except (TypeError, ValueError):
                    pass
        for key, _, default_window in self.graph_options:
            visible = settings.value(f"graphs/{key}/visible", True, type=bool)
            window = settings.value(f"graphs/{key}/window_s", default_window, type=int)
            self.graph_time_windows[key] = window
            self._set_graph_visibility(key, visible)
            self.processor.set_graph_unlimited(key, window == 0)

    def _save_settings(self) -> None:
        settings = self._settings
        settings.setValue("user/weight_kg", self.processor.weight_kg)
        settings.setValue("ui/theme", getattr(self, "_theme", "Dark"))
        for key, _, default_window in self.graph_options:
            settings.setValue(
                f"graphs/{key}/visible", self.graph_visibility.get(key, True)
            )
            settings.setValue(
                f"graphs/{key}/window_s",
                int(self.graph_time_windows.get(key, default_window)),
            )
        settings.sync()

    def open_settings(self) -> None:
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle("Settings")
        layout = QtWidgets.QVBoxLayout(dialog)

        form = QtWidgets.QFormLayout()
        weight_spin = QtWidgets.QDoubleSpinBox()
        weight_spin.setRange(20.0, 200.0)
        weight_spin.setDecimals(1)
        weight_spin.setSingleStep(0.5)
        weight_spin.setValue(self.processor.weight_kg)
        form.addRow("Weight (kg):", weight_spin)

        theme_combo = QtWidgets.QComboBox()
        theme_combo.addItems(["Dark", "Light"])
        theme_combo.setCurrentText(getattr(self, "_theme", "Dark"))
        form.addRow("Theme:", theme_combo)
        layout.addLayout(form)

        layout.addWidget(QtWidgets.QLabel("Graphs:"))
        graph_layout = QtWidgets.QGridLayout()
        graph_layout.addWidget(QtWidgets.QLabel("Show"), 0, 0)
        graph_layout.addWidget(QtWidgets.QLabel("Time window (s, 0 = unlimited)"), 0, 1)
        graph_checks = {}
        graph_windows = {}
        row = 1
        for key, label, default_window in self.graph_options:
            checkbox = QtWidgets.QCheckBox(label)
            checkbox.setChecked(self.graph_visibility.get(key, True))
            graph_checks[key] = checkbox
            window_spin = QtWidgets.QSpinBox()
            window_spin.setRange(0, 3600)
            window_spin.setSingleStep(5)
            window_spin.setSuffix(" s")
            window_spin.setSpecialValueText("Unlimited")
            window_spin.setValue(self.graph_time_windows.get(key, default_window))
            graph_windows[key] = window_spin
            graph_layout.addWidget(checkbox, row, 0)
            graph_layout.addWidget(window_spin, row, 1)
            row += 1
        layout.addLayout(graph_layout)

        buttons = QtWidgets.QDialogButtonBox(
            QtWidgets.QDialogButtonBox.Ok | QtWidgets.QDialogButtonBox.Cancel
        )
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)

        if exec_dialog(dialog) == QtWidgets.QDialog.Accepted:
            self.processor.set_weight_kg(weight_spin.value())
            self.apply_theme(theme_combo.currentText())
            for key, checkbox in graph_checks.items():
                self._set_graph_visibility(key, checkbox.isChecked())
            for key, window_spin in graph_windows.items():
                self.graph_time_windows[key] = window_spin.value()
                self.processor.set_graph_unlimited(key, window_spin.value() == 0)
            self._save_settings()

    def set_status(self, text: str) -> None:
        self.status_label.setText(text)
        connected = text.startswith("Connected")
        if connected != self._connected:
            self._connected = connected
            if not connected:
                self.processor.reset()
                self._base_time = time.time()
                for axis in self._time_axes:
                    axis.set_base_time(self._base_time)
                self.refresh()

    def toggle_recording(self) -> None:
        if self.recorder.is_recording():
            self.recorder.stop()
            self.record_button.setText("Start Recording")
            self._status_cb("Recording stopped.")
            return
        path = self.recorder.start(self.processor.config)
        self.record_button.setText("Stop Recording")
        self._status_cb(f"Recording to {path}")

    def apply_theme(self, theme: str) -> None:
        self._theme = theme
        if theme == "Light":
            bg = "#f6f6f6"
            fg = "#202020"
            btn_bg = "#ffffff"
            btn_border = "#c0c0c0"
            btn_hover = "#e9e9e9"
            btn_pressed = "#d9d9d9"
            input_bg = "#ffffff"
        else:
            bg = "#121212"
            fg = "#e0e0e0"
            btn_bg = "#2b2b2b"
            btn_border = "#3a3a3a"
            btn_hover = "#3a3a3a"
            btn_pressed = "#1f1f1f"
            input_bg = "#1e1e1e"
        style = (
            "QWidget {{ background-color: {bg}; color: {fg}; }}"
            "QPushButton {{ background-color: {btn_bg}; color: {fg};"
            " border: 1px solid {btn_border}; padding: 6px 10px; border-radius: 4px; }}"
            "QPushButton:hover {{ background-color: {btn_hover}; }}"
            "QPushButton:pressed {{ background-color: {btn_pressed}; }}"
            "QComboBox, QDoubleSpinBox, QSpinBox {{ background-color: {input_bg}; color: {fg};"
            " border: 1px solid {btn_border}; padding: 2px 6px; }}"
            "QCheckBox {{ color: {fg}; }}"
        ).format(
            bg=bg,
            fg=fg,
            btn_bg=btn_bg,
            btn_border=btn_border,
            btn_hover=btn_hover,
            btn_pressed=btn_pressed,
            input_bg=input_bg,
        )
        self.setStyleSheet(style)
        for plot in [
            self.pressure_plot,
            self.breath_plot,
            self.gas_plot,
            self.vo2_plot,
            self.ve_plot,
            self.ve_vo2_plot,
            self.ve_vco2_plot,
            self.temp_plot,
        ]:
            plot.setBackground(bg)
            for axis_name in ("left", "bottom"):
                axis = plot.getAxis(axis_name)
                axis.setPen(pg.mkPen(fg))
                axis.setTextPen(pg.mkPen(fg))

    def _apply_time_window(self, plot, times_list, key: str, fallback_time=None) -> None:
        window_s = self.graph_time_windows.get(key)
        if window_s is None:
            return
        last_t = fallback_time
        for times in times_list:
            if times:
                t = times[-1]
                if last_t is None or t > last_t:
                    last_t = t
        if last_t is None:
            return
        if window_s == 0:
            min_t = None
            for times in times_list:
                if times:
                    t0 = times[0]
                    if min_t is None or t0 < min_t:
                        min_t = t0
            if min_t is None:
                min_t = 0.0
        else:
            min_t = max(0.0, last_t - window_s)
        plot.setXRange(min_t, last_t, padding=0.0)

    def refresh(self) -> None:
        p = self.processor
        last_t = p.pressure_times[-1] if p.pressure_times else None
        self.pressure_curve.setData(list(p.pressure_times), list(p.pressure_vals))
        points = [{"pos": (t, v)} for t, v in zip(p.breath_times, p.breath_vols)]
        self.breath_scatter.setData(points)
        self.o2_curve.setData(list(p.o2_times), list(p.o2_vals))
        self.co2_curve.setData(list(p.co2_times), list(p.co2_vals))
        self.vo2_curve.setData(list(p.vo2_times), list(p.vo2_vals))
        self.ve_curve.setData(list(p.ve_times), list(p.ve_vals))
        self.ve_vo2_curve.setData(list(p.ve_vo2_times), list(p.ve_vo2_vals))
        self.ve_vco2_curve.setData(list(p.ve_vco2_times), list(p.ve_vco2_vals))
        self.temp_curve.setData(list(p.temp_times), list(p.temp_vals))
        self._apply_time_window(
            self.pressure_plot, [p.pressure_times], "pressure", fallback_time=last_t
        )
        self._apply_time_window(
            self.breath_plot, [p.breath_times], "breath", fallback_time=last_t
        )
        self._apply_time_window(
            self.gas_plot, [p.o2_times, p.co2_times], "gas", fallback_time=last_t
        )
        self._apply_time_window(
            self.vo2_plot, [p.vo2_times], "vo2", fallback_time=last_t
        )
        self._apply_time_window(
            self.ve_plot, [p.ve_times], "ve", fallback_time=last_t
        )
        self._apply_time_window(
            self.ve_vo2_plot, [p.ve_vo2_times], "ve_vo2", fallback_time=last_t
        )
        self._apply_time_window(
            self.ve_vco2_plot, [p.ve_vco2_times], "ve_vco2", fallback_time=last_t
        )
        self._apply_time_window(
            self.temp_plot, [p.temp_times], "temp", fallback_time=last_t
        )
        roll = p.vo2_roll
        roll_text = "--" if roll is None else f"{roll:.1f}"
        self.vo2max_label.setText(
            f"VO2Max ({p.vo2_window_sec:.0f}s avg): {p.vo2_max:.1f} (current {roll_text})"
        )
        ve = p.ve_latest
        ve_text = "--" if ve is None else f"{ve:.1f}"
        self.ve_label.setText(f"VE: {ve_text} L/min")
        vt = p.vt_status
        vt_text = "--" if vt is None else vt
        self.vt_label.setText(f"VT: {vt_text}")
        temp = p._last_temp
        temp_text = "--" if temp is None else f"{temp:.1f}\u00b0C"
        self.temp_label.setText(f"Temp: {temp_text}")
        battery = p.battery_percent
        battery_text = "--" if battery is None else f"{battery:d}%"
        self.battery_label.setText(f"Battery: {battery_text}")
        self.kcal_label.setText(f"kcal: {p.kcal_total:.1f}")

    def closeEvent(self, event: QtGui.QCloseEvent) -> None:
        if self._on_close:
            self._on_close()
        super().closeEvent(event)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BLE VO2 raw stream plotter")
    parser.add_argument("--device-name", default="SpiroVO2-RAW")
    parser.add_argument("--weight-kg", type=float, default=None)
    parser.add_argument("--vo2-window-sec", type=float, default=15.0)
    parser.add_argument("--pressure-deadband-pa", type=float, default=0.1)
    parser.add_argument("--flow-start-l-s", type=float, default=0.3)
    parser.add_argument("--flow-end-l-s", type=float, default=0.15)
    parser.add_argument("--min-breath-l", type=float, default=0.1)
    parser.add_argument("--min-breath-s", type=float, default=0.3)
    parser.add_argument("--breath-start-hold-ms", type=float, default=50.0)
    parser.add_argument("--breath-end-hold-ms", type=float, default=150.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    weight = args.weight_kg

    app = QtWidgets.QApplication([])
    QtCore.QCoreApplication.setOrganizationName("VO2Mask")
    QtCore.QCoreApplication.setApplicationName("BleVo2Plot")
    settings = QtCore.QSettings()
    if args.weight_kg is None:
        weight = settings.value("user/weight_kg", 80.0, type=float)
    else:
        weight = args.weight_kg

    queue: Queue = Queue()

    status_holder = {"text": "Starting..."}

    def status_cb(text: str):
        status_holder["text"] = text

    base_dir = Path(__file__).resolve().parents[2] / "Recordings"
    recorder = Recorder(base_dir=base_dir)
    processor = Vo2Processor(
        weight_kg=weight,
        vo2_window_sec=args.vo2_window_sec,
        pressure_deadband_pa=args.pressure_deadband_pa,
        flow_start_l_s=args.flow_start_l_s,
        flow_end_l_s=args.flow_end_l_s,
        min_breath_l=args.min_breath_l,
        min_breath_s=args.min_breath_s,
        start_hold_s=args.breath_start_hold_ms / 1000.0,
        end_hold_s=args.breath_end_hold_ms / 1000.0,
    )
    window = PlotWindow(
        processor,
        recorder,
        status_cb,
        load_weight_from_settings=(args.weight_kg is None),
    )
    window.resize(900, 800)
    window.show()

    worker = BleWorker(args.device_name, queue, status_cb)
    worker.start()

    timer = QtCore.QTimer()
    timer.setInterval(50)

    def pump_queue():
        window.set_status(status_holder["text"])
        while True:
            try:
                payload = queue.get_nowait()
            except Empty:
                break
            processor.handle_packet(payload)
        if recorder.is_recording():
            samples = processor.pop_record_samples()
            if samples:
                recorder.write_samples(samples)
        window.refresh()

    timer.timeout.connect(pump_queue)
    timer.start()

    def cleanup():
        worker.stop()

    window._on_close = cleanup
    app.aboutToQuit.connect(cleanup)

    exit_code = exec_app(app)
    worker.stop()
    worker.join(timeout=2.0)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
