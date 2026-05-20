import tempfile
import unittest
from datetime import datetime
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from recording_alignment import (  # noqa: E402
    AlignedCsvFrame,
    LatchedHrValues,
    MERGED_CSV_HEADER,
    MaskWallClockAligner,
    PulseBandRecordRow,
    Vo2RecordRow,
    frame_index_for_elapsed,
    iso_timestamp,
    is_post_start_sample,
    render_aligned_frame,
    resolve_recording_output_path,
)


class RecordingAlignmentTests(unittest.TestCase):
    def test_iso_timestamp_uses_millisecond_precision(self):
        wall_time_s = datetime(2026, 2, 19, 15, 32, 46, 50000).timestamp()
        self.assertEqual(iso_timestamp(wall_time_s), "2026-02-19T15:32:46.050")

    def test_mask_aligner_anchors_from_pressure_end_sample(self):
        aligner = MaskWallClockAligner()
        packet_wall_time_s = datetime(2026, 2, 19, 15, 32, 46, 200000).timestamp()
        aligner.observe_point(926.395, packet_wall_time_s)

        wall_time_s = aligner.wall_time(926.365)
        self.assertIsNotNone(wall_time_s)
        self.assertEqual(iso_timestamp(wall_time_s), "2026-02-19T15:32:46.170")

    def test_mask_aligner_can_anchor_from_gas_before_pressure(self):
        aligner = MaskWallClockAligner()
        packet_wall_time_s = datetime(2026, 2, 19, 15, 32, 40).timestamp()
        aligner.observe_point(920.0, packet_wall_time_s)
        aligner.observe_point(930.0, packet_wall_time_s + 30.0)

        wall_time_s = aligner.wall_time(921.25)
        self.assertIsNotNone(wall_time_s)
        self.assertEqual(iso_timestamp(wall_time_s), "2026-02-19T15:32:41.250")

    def test_frame_index_for_elapsed_quantizes_to_200hz_grid(self):
        self.assertEqual(frame_index_for_elapsed(0.0, 200.0), 0)
        self.assertEqual(frame_index_for_elapsed(0.0049, 200.0), 1)
        self.assertEqual(frame_index_for_elapsed(0.0101, 200.0), 2)

    def test_is_post_start_sample_drops_pre_start_rows(self):
        self.assertFalse(is_post_start_sample(99.99, 100.0))
        self.assertTrue(is_post_start_sample(100.0, 100.0))
        self.assertTrue(is_post_start_sample(100.01, 100.0))

    def test_merge_header_matches_wide_row_shape(self):
        self.assertEqual(
            MERGED_CSV_HEADER,
            (
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
            ),
        )

    def test_aligned_frame_merges_mask_and_pulse_values(self):
        frame = AlignedCsvFrame()
        frame.apply_vo2(
            Vo2RecordRow(
                wall_time_s=100.25,
                t_s=926.365,
                sample_idx=185273,
                pressure_pa=-0.4,
                flow_l_s=0.16,
                breath_number=7,
                breath_vol_l=0.0,
                ve_l_min=40.6,
                o2_pct=17.94,
                co2_pct=6.5165,
                vo2_ml_kg_min=11.0,
                vo2_roll_ml_kg_min=11.0,
                vo2_roll_max_ml_kg_min=13.9,
                kcal_total=21.5,
            )
        )
        frame.apply_pulse(
            PulseBandRecordRow(
                wall_time_s=100.25,
                elapsed_s=613.95,
                event_type="pulse_ecg",
                ecg_heart_adc=-11068,
                ecg_breath_adc=3615737,
                accel_x_g=None,
                accel_y_g=None,
                accel_z_g=None,
                gyro_x_dps=None,
                gyro_y_dps=None,
                gyro_z_dps=None,
                imu_sample_idx=None,
                heart_rate_bpm=None,
                hrv_rr_ms=None,
                seq=10,
            )
        )

        cells = render_aligned_frame(
            0,
            100.25,
            200.0,
            frame,
            LatchedHrValues(),
        )
        self.assertEqual(cells[0], iso_timestamp(100.25))
        self.assertEqual(cells[1], "0.0")
        self.assertEqual(cells[2], "926.365")
        self.assertEqual(cells[3], "613.95")
        self.assertEqual(cells[4], "185273")
        self.assertEqual(cells[6], "-11068")
        self.assertEqual(cells[7], "3615737")
        self.assertEqual(cells[16], "-0.4")
        self.assertEqual(cells[18], "7")
        self.assertEqual(cells[26], "21.5")

    def test_render_aligned_frame_latches_hr_and_hrv(self):
        latched = LatchedHrValues()
        hr_frame = AlignedCsvFrame()
        hr_frame.apply_pulse(
            PulseBandRecordRow(
                wall_time_s=200.05,
                elapsed_s=613.97,
                event_type="pulse_hr",
                ecg_heart_adc=None,
                ecg_breath_adc=None,
                accel_x_g=None,
                accel_y_g=None,
                accel_z_g=None,
                gyro_x_dps=None,
                gyro_y_dps=None,
                gyro_z_dps=None,
                imu_sample_idx=None,
                heart_rate_bpm=60,
                hrv_rr_ms=None,
                seq=12,
            )
        )
        hrv_frame = AlignedCsvFrame()
        hrv_frame.apply_pulse(
            PulseBandRecordRow(
                wall_time_s=200.06,
                elapsed_s=613.98,
                event_type="pulse_hrv",
                ecg_heart_adc=None,
                ecg_breath_adc=None,
                accel_x_g=None,
                accel_y_g=None,
                accel_z_g=None,
                gyro_x_dps=None,
                gyro_y_dps=None,
                gyro_z_dps=None,
                imu_sample_idx=None,
                heart_rate_bpm=None,
                hrv_rr_ms=500,
                seq=13,
            )
        )

        hr_cells = render_aligned_frame(0, 200.0, 200.0, hr_frame, latched)
        gap_cells = render_aligned_frame(1, 200.0, 200.0, None, latched)
        hrv_cells = render_aligned_frame(2, 200.0, 200.0, hrv_frame, latched)

        self.assertEqual(hr_cells[14], "60")
        self.assertEqual(hr_cells[15], "")
        self.assertEqual(gap_cells[1], "0.005")
        self.assertEqual(gap_cells[14], "60")
        self.assertEqual(gap_cells[15], "")
        self.assertEqual(hrv_cells[14], "60")
        self.assertEqual(hrv_cells[15], "500")

    def test_aligned_frame_preserves_imu_fields_on_sparse_rows(self):
        frame = AlignedCsvFrame()
        frame.apply_pulse(
            PulseBandRecordRow(
                wall_time_s=200.06,
                elapsed_s=613.96,
                event_type="pulse_imu",
                ecg_heart_adc=None,
                ecg_breath_adc=None,
                accel_x_g=-0.12261,
                accel_y_g=0.975268,
                accel_z_g=-0.049532,
                gyro_x_dps=4.8475,
                gyro_y_dps=-0.63,
                gyro_z_dps=-1.4175,
                imu_sample_idx=124275,
                heart_rate_bpm=None,
                hrv_rr_ms=None,
                seq=11,
            )
        )

        cells = render_aligned_frame(2, 200.0, 200.0, frame, LatchedHrValues())
        self.assertEqual(cells[1], "0.01")
        self.assertEqual(cells[5], "124275")
        self.assertEqual(cells[8], "-0.12261")
        self.assertEqual(cells[13], "-1.4175")
        self.assertEqual(cells[16], "")

    def test_resolve_recording_output_path_prefers_new_flag(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = resolve_recording_output_path(
                str(Path(tmpdir)),
                "/tmp/legacy.csv",
                Path("/unused"),
                now=datetime(2026, 3, 4, 17, 58, 45),
            )
        self.assertEqual(output.name, "session_recording_20260304_175845.csv")

    def test_resolve_recording_output_path_uses_legacy_alias(self):
        output = resolve_recording_output_path(
            None,
            "/tmp/legacy.csv",
            Path("/unused"),
            now=datetime(2026, 3, 4, 17, 58, 45),
        )
        self.assertEqual(output, Path("/tmp/legacy.csv"))


if __name__ == "__main__":
    unittest.main()
