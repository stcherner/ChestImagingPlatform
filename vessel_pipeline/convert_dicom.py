#!/usr/bin/env python3
"""
Convert a directory of DICOM slices to a single nrrd volume.
Replaces ConvertDicom (CIP CLI tool).

Usage:
    python convert_dicom.py -i /path/to/dicom_dir -o output.nrrd
"""

import argparse
import os
import sys
import SimpleITK as sitk


def convert_dicom(dicom_dir: str, out_nrrd: str) -> None:
    reader = sitk.ImageSeriesReader()
    series_ids = reader.GetGDCMSeriesIDs(dicom_dir)
    if not series_ids:
        raise RuntimeError(f"No DICOM series found in {dicom_dir}")

    if len(series_ids) > 1:
        # Pick the series with the most slices (most likely the primary CT volume)
        counts = {sid: len(reader.GetGDCMSeriesFileNames(dicom_dir, sid))
                  for sid in series_ids}
        print(f"Warning: {len(series_ids)} DICOM series found:")
        for sid, n in sorted(counts.items(), key=lambda x: -x[1]):
            print(f"  {sid}: {n} slices")
        selected = max(counts, key=counts.__getitem__)
        print(f"Selected series with most slices: {selected} ({counts[selected]} slices)")
        series_ids = [selected]

    file_names = reader.GetGDCMSeriesFileNames(dicom_dir, series_ids[0])
    reader.SetFileNames(file_names)
    reader.MetaDataDictionaryArrayUpdateOn()
    reader.LoadPrivateTagsOn()

    image = reader.Execute()
    print(f"Read {image.GetDepth()} slices, "
          f"size={image.GetSize()}, spacing={image.GetSpacing()}")

    sitk.WriteImage(image, out_nrrd)
    print(f"Written to {out_nrrd}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DICOM directory -> nrrd volume")
    parser.add_argument("-i", dest="dicom_dir", required=True,
                        help="Input DICOM directory")
    parser.add_argument("-o", dest="out_nrrd", required=True,
                        help="Output nrrd file")
    op = parser.parse_args()

    if not os.path.isdir(op.dicom_dir):
        sys.exit(f"ERROR: {op.dicom_dir} is not a directory")

    convert_dicom(op.dicom_dir, op.out_nrrd)
