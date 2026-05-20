# VO2 BLE Stream Plotter

This tool connects to the ESP32 BLE stream (`SpiroVO2-RAW`), decodes pressure/O2/CO2 packets, computes breath volume, and plots results in real time.

## Install

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

On Windows, the requirements file installs `PySide6` instead of `PyQt5`. This avoids the
`PyQt5-Qt5` wheel issue that can show up with the checked-in `uv.lock`.

If you are using `uv` instead of `pip`, refresh the lock before syncing:

```bash
uv lock
uv sync
```

## Run

```bash
python vo2_ble_plot.py --weight-kg 70
```

If you omit `--weight-kg`, the script uses the last saved Settings weight (or **80 kg** if none).
Passing `--weight-kg` overrides the saved value for that run.

## Notes
- Pressure is streamed at **200 Hz** in batched BLE packets.
- Breath volume is computed on the PC from the venturi equation (one dot per breath).
- VO2 is computed using the O2 stream (1 Hz) and smoothed ventilation.
- VO2Max is the **highest rolling average** (default 15 s). Use `--vo2-window-sec` to adjust.
- Numeric readouts: VO2Max, VE, VT status, battery, and kcal.
- Graphs: Pressure, breath volume, O2/CO2, VO2, VE, VE/VO2, VE/VCO2, pulse-band HR, and pulse-band HRV.
- Settings are remembered between runs (theme, weight, graph visibility, time windows).
- Settings lets you tune flow correction and breath detection, toggle which graphs are visible, adjust weight, pick a theme, and set time windows (0 = unlimited).
- VT status uses a simple short-vs-long window change heuristic for VE/VO2 and VE/VCO2.
- Use **Start Recording** to write one merged CSV in `Recordings/` at the repo root.
- The merged CSV is a fixed-rate wide table with one row per sample step instead of separate event rows.
- Rows are quantized to the active sample grid (default **200 Hz**), so `session_elapsed_s` advances by `1 / sample_rate_hz` each row.
- `session_elapsed_s` is anchored to the first kept sample after you press **Start Recording**.
- A few samples from the first BLE batch may be omitted if they were captured just before recording started.
- `timestamp` advances on that same fixed grid, `mask_t_s` remains the mask device time, and `pulse_elapsed_s` remains the pulse-band local elapsed time when a new pulse-band sample lands on that row.
- Pulse-band HR and HRV are latched forward in the CSV so each row carries the latest decoded values after they first arrive.
- Use `--recording-output-path` to choose the merged CSV output path. `--ecg-output-path` is kept as a deprecated alias for compatibility.
- Use `--no-pulse-band` to run in mask-only mode without connecting to the pulse band.
- Breath detection can be tuned to reduce false positives:
  - `--pressure-deadband-pa` (default 0.1)
  - `--flow-start-l-s` / `--flow-end-l-s`
  - `--min-breath-l`, `--min-breath-s`
  - `--breath-start-hold-ms`, `--breath-end-hold-ms`
  - `--max-breath-s` (force-close timeout)
- The app keeps scanning and will reconnect automatically if the device appears or disconnects.
- CO2 expects an **SCD30** sensor and is plotted in % (ppm / 10000).

If you see no data, verify that your ESP32 is advertising as `SpiroVO2-RAW` and that BLE is enabled on your machine.
