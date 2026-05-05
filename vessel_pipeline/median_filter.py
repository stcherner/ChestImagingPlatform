#!/usr/bin/env python3
"""
Apply a median filter to a nrrd volume.
Replaces GenerateMedianFilteredImage (CIP CLI tool).

Usage:
    python median_filter.py -i input.nrrd -o output.nrrd --radius 1
"""

import argparse
import SimpleITK as sitk


def median_filter(in_nrrd: str, out_nrrd: str, radius: int = 1) -> None:
    img = sitk.ReadImage(in_nrrd)
    filt = sitk.MedianImageFilter()
    filt.SetRadius(radius)
    filtered = filt.Execute(img)
    sitk.WriteImage(filtered, out_nrrd)
    print(f"Median filter (radius={radius}) applied: {out_nrrd}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Median filter for nrrd volumes")
    parser.add_argument("-i", dest="in_nrrd", required=True)
    parser.add_argument("-o", dest="out_nrrd", required=True)
    parser.add_argument("--radius", dest="radius", type=int, default=1,
                        help="Median filter radius in voxels (default: 1)")
    op = parser.parse_args()
    median_filter(op.in_nrrd, op.out_nrrd, op.radius)
