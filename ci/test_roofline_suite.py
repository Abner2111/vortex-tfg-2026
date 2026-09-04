#!/usr/bin/env python3

import os
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import roofline_suite as rs


class RooflineSuiteTest(unittest.TestCase):
    def test_flops_formulas(self):
        by_key = {k: f for k, _, _, f, _ in rs.BENCHMARKS}
        self.assertEqual(by_key["matmul"](128), 2 * 128 ** 3)
        self.assertEqual(by_key["conv"](64), 18 * 64 * 64)
        self.assertEqual(by_key["softmax"](128), 4 * 128 * 128)
        self.assertEqual(by_key["relu"](65536), 65536)

    def test_parse_sizes(self):
        self.assertEqual(rs.parse_sizes("matmul=256,conv=128"),
                          {"matmul": 256, "conv": 128})
        self.assertEqual(rs.parse_sizes(""), {})

    def test_plot_system_roofline_writes_file(self):
        args = SimpleNamespace(freq=0, bw=None, peak_flops=None, driver="simx")
        cfg = {"cores": 1, "threads": 4, "fpu_blocks": 1}
        points = [("matmul", 0.5, 4194304, 100000, 2.0)]
        with tempfile.TemporaryDirectory() as tmp:
            outfile = os.path.join(tmp, "out.png")
            rs.plot_system_roofline(args, cfg, points, outfile)
            self.assertTrue(os.path.isfile(outfile))
            self.assertGreater(os.path.getsize(outfile), 0)


if __name__ == "__main__":
    unittest.main()
