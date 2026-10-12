"""Chlorophyll-a / bloom detector from Sentinel-2 surface reflectance.

Pure numpy so it can be unit-tested without rasterio. Method follows Stirling's small-water
findings (NDCI best for S2, R2~0.6) with a per-optical-class calibration fitted against EA samples.
"""
from __future__ import annotations

import numpy as np

ALGO_VERSION = "ndci-v1"
SCL_WATER = 6
# SCL classes to reject: no data, saturated, shadow, cloud (med/high), cirrus, snow
SCL_BAD = (0, 1, 3, 8, 9, 10, 11)


def ndci(b4: np.ndarray, b5: np.ndarray) -> np.ndarray:
    """Normalised Difference Chlorophyll Index (B5 705nm - B4 665nm) / (B5 + B4)."""
    b4 = b4.astype("float32")
    b5 = b5.astype("float32")
    den = b5 + b4
    with np.errstate(divide="ignore", invalid="ignore"):
        out = (b5 - b4) / den
    out[den <= 0] = np.nan
    return out


def water_mask(scl: np.ndarray, b3: np.ndarray, b8: np.ndarray, erode: bool = True) -> np.ndarray:
    """SCL water AND NDWI>0, with 1-pixel erosion to drop mixed land/water edge pixels."""
    with np.errstate(divide="ignore", invalid="ignore"):
        ndwi = (b3.astype("float32") - b8.astype("float32")) / (b3 + b8)
    m = (scl == SCL_WATER) & (ndwi > 0)
    if erode:
        p = np.pad(m, 1, constant_values=False)
        m = (
            p[1:-1, 1:-1] & p[:-2, 1:-1] & p[2:, 1:-1] & p[1:-1, :-2] & p[1:-1, 2:]
        )
    return m


def quality_mask(scl: np.ndarray, b8: np.ndarray, max_nir: float = 0.1) -> np.ndarray:
    """True where the pixel is usable: not cloud/shadow/cirrus, and NIR low enough to rule out glint/scum/bottom."""
    return ~np.isin(scl, SCL_BAD) & (b8 < max_nir)


def to_chl(index: np.ndarray, coef: dict | None) -> np.ndarray:
    """Apply a calibration. Default linear ndci->log10(chl) from literature-style prior until we fit our own."""
    c = coef or {"a": 14.04, "b": 86.115, "c": 194.325}   # Mishra & Mishra 2012 quadratic, chl = a + b*x + c*x^2
    return c["a"] + c["b"] * index + c["c"] * index**2


def reach_metrics(
    b3: np.ndarray, b4: np.ndarray, b5: np.ndarray, b8: np.ndarray, scl: np.ndarray,
    reach_mask: np.ndarray, coef: dict | None = None, bloom_chl: float = 30.0,
) -> dict | None:
    """Per-reach metrics from co-registered band windows. Returns None when no clean water pixels."""
    wet = water_mask(scl, b3, b8) & reach_mask
    n_wet = int(wet.sum())
    n_reach = int(reach_mask.sum())
    if n_wet == 0:
        return None
    ok = wet & quality_mask(scl, b8)
    n_ok = int(ok.sum())
    if n_ok == 0:
        return None
    idx = ndci(b4, b5)[ok]
    idx = idx[np.isfinite(idx)]
    if idx.size == 0:
        return None
    chl = np.clip(to_chl(idx, coef), 0, None)
    return {
        "ndci_median": float(np.median(idx)),
        "chl_median": float(np.median(chl)),
        "chl_p90": float(np.percentile(chl, 90)),
        "bloom_frac": float((chl >= bloom_chl).mean()),
        "n_pixels": int(idx.size),
        "valid_frac": n_ok / max(n_reach, 1),
        "turbidity_b4": float(np.median(b4[ok])),
    }


def confidence(m: dict, observable: bool) -> float:
    """Heuristic 0-1: more clean pixels and higher valid fraction -> more trust; unobservable reaches capped."""
    c = min(1.0, m["n_pixels"] / 30) * min(1.0, m["valid_frac"] * 2)
    return round(c * (1.0 if observable else 0.4), 3)
