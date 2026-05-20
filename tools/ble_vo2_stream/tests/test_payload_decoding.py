import struct
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pulse_band_protocol import (  # noqa: E402
    ACCEL_G_PER_LSB,
    GRAVITY,
    GYRO_DPS_PER_LSB,
    SampleGapTracker,
    convert_raw_imu,
    decode_breath_payload,
    decode_hrm_payload,
    decode_hr_payload,
    decode_imu_payload,
)


class PayloadDecodingTests(unittest.TestCase):
    def test_decode_breath_payload_batched(self):
        payload = struct.pack("<IiIi", 100, 300, 101, 301)
        samples = decode_breath_payload(payload)
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[0].sample_count, 100)
        self.assertEqual(samples[0].breathing, 300)
        self.assertEqual(samples[1].sample_count, 101)
        self.assertEqual(samples[1].breathing, 301)

    def test_decode_imu_payload_batched(self):
        payload = struct.pack(
            "<IhhhhhhIhhhhhh",
            10,
            1,
            -2,
            3,
            -4,
            5,
            -6,
            11,
            7,
            -8,
            9,
            -10,
            11,
            -12,
        )
        samples = decode_imu_payload(payload)
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[0].sample_count, 10)
        self.assertEqual(samples[0].ax, 1)
        self.assertEqual(samples[0].ay, -2)
        self.assertEqual(samples[0].az, 3)
        self.assertEqual(samples[0].gx, -4)
        self.assertEqual(samples[0].gy, 5)
        self.assertEqual(samples[0].gz, -6)
        self.assertEqual(samples[1].sample_count, 11)
        self.assertEqual(samples[1].ax, 7)
        self.assertEqual(samples[1].ay, -8)
        self.assertEqual(samples[1].az, 9)
        self.assertEqual(samples[1].gx, -10)
        self.assertEqual(samples[1].gy, 11)
        self.assertEqual(samples[1].gz, -12)

    def test_decode_length_validation(self):
        with self.assertRaises(ValueError):
            decode_breath_payload(b"\x00" * 9)
        with self.assertRaises(ValueError):
            decode_imu_payload(b"\x00" * 15)
        with self.assertRaises(ValueError):
            decode_hr_payload(b"")
        with self.assertRaises(ValueError):
            decode_hrm_payload(b"\x00")
        with self.assertRaises(ValueError):
            decode_hrm_payload(b"\x10\x3c\x01")

    def test_decode_hr_payload(self):
        self.assertEqual(decode_hr_payload(b"\x00\x3c"), 60)
        self.assertEqual(decode_hr_payload(b"\xff"), -1)

    def test_decode_hrm_payload(self):
        bpm, rr_ms_values = decode_hrm_payload(b"\x10\x3c\x00\x04")
        self.assertEqual(bpm, 60)
        self.assertEqual(rr_ms_values, [1000])

    def test_gap_tracker(self):
        tracker = SampleGapTracker()
        self.assertEqual(tracker.observe(100), 0)
        self.assertEqual(tracker.observe(101), 0)
        self.assertEqual(tracker.observe(104), 2)
        self.assertEqual(tracker.gaps, 2)
        self.assertEqual(tracker.observe(104), 0)
        self.assertEqual(tracker.duplicates, 1)

    def test_imu_conversion_constants(self):
        conv = convert_raw_imu(ax=1000, ay=-1000, az=500, gx=100, gy=-100, gz=200)
        self.assertAlmostEqual(conv.ax_g, 1000 * ACCEL_G_PER_LSB)
        self.assertAlmostEqual(conv.ay_g, -1000 * ACCEL_G_PER_LSB)
        self.assertAlmostEqual(conv.az_g, 500 * ACCEL_G_PER_LSB)
        self.assertAlmostEqual(conv.gx_dps, 100 * GYRO_DPS_PER_LSB)
        self.assertAlmostEqual(conv.gy_dps, -100 * GYRO_DPS_PER_LSB)
        self.assertAlmostEqual(conv.gz_dps, 200 * GYRO_DPS_PER_LSB)
        self.assertAlmostEqual(conv.ax_ms2, conv.ax_g * GRAVITY)
        self.assertAlmostEqual(conv.ay_ms2, conv.ay_g * GRAVITY)
        self.assertAlmostEqual(conv.az_ms2, conv.az_g * GRAVITY)


if __name__ == "__main__":
    unittest.main()
