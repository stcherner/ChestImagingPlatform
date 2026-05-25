#!/usr/bin/env python3
"""Convert a NIfTI (.nii / .nii.gz) volume to NRRD, preserving spacing and orientation."""
import argparse
import SimpleITK as sitk

parser = argparse.ArgumentParser(description="NIfTI → NRRD converter")
parser.add_argument("-i", dest="in_file",  required=True, help="Input .nii or .nii.gz")
parser.add_argument("-o", dest="out_file", required=True, help="Output .nrrd")
op = parser.parse_args()

img = sitk.ReadImage(op.in_file)
sitk.WriteImage(img, op.out_file)
print(f"Converted: size={img.GetSize()} spacing={img.GetSpacing()} → {op.out_file}")
