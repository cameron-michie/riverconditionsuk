import unittest

import numpy as np

from eo_worker.detectors import chlorophyll as c


def scene(red, rededge, n=20):
    shp = (n, n)
    scl = np.full(shp, 6, dtype="uint8")
    b3 = np.full(shp, 0.06, "float32")
    b4 = np.full(shp, red, "float32")
    b5 = np.full(shp, rededge, "float32")
    b8 = np.full(shp, 0.02, "float32")
    return b3, b4, b5, b8, scl, np.ones(shp, bool)


class Chlorophyll(unittest.TestCase):
    def test_ndci_sign(self):
        self.assertGreater(c.ndci(np.array([0.02]), np.array([0.05]))[0], 0)
        self.assertLess(c.ndci(np.array([0.05]), np.array([0.02]))[0], 0)

    def test_bloom_scores_higher_than_clear(self):
        clear = c.reach_metrics(*scene(0.03, 0.025))
        bloom = c.reach_metrics(*scene(0.03, 0.06))
        self.assertGreater(bloom["chl_median"], clear["chl_median"])
        self.assertGreaterEqual(bloom["bloom_frac"], 0.99)
        self.assertEqual(clear["bloom_frac"], 0.0)

    def test_cloud_pixels_rejected(self):
        b3, b4, b5, b8, scl, rm = scene(0.03, 0.06)
        scl[:] = 9  # all cloud
        self.assertIsNone(c.reach_metrics(b3, b4, b5, b8, scl, rm))

    def test_land_is_not_water(self):
        b3, b4, b5, b8, scl, rm = scene(0.03, 0.06)
        scl[:] = 4  # vegetation
        self.assertIsNone(c.reach_metrics(b3, b4, b5, b8, scl, rm))

    def test_erosion_drops_edge_pixels(self):
        scl = np.full((5, 5), 6, "uint8")
        b = np.full((5, 5), 0.05, "float32")
        m = c.water_mask(scl, b, b * 0.2)
        self.assertEqual(int(m.sum()), 9)  # 5x5 -> 3x3 interior

    def test_unobservable_confidence_capped(self):
        m = c.reach_metrics(*scene(0.03, 0.06))
        self.assertLess(c.confidence(m, False), c.confidence(m, True))


if __name__ == "__main__":
    unittest.main()
