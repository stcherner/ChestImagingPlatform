#!/usr/bin/env python3
"""
Generate a partial lung label map from a CT nrrd volume.
Replaces GeneratePartialLungLabelMap (CIP CLI tool).

Encoding (CIP convention):
    value = (chest_type << 8) | chest_region
    chest_type   = 0 (UndefinedType)
    chest_region = 1 (WholeLung), 2 (RightLung), 3 (LeftLung)

Output is a uint16 nrrd where each lung voxel is labelled:
    2 = RightLung (right side of patient = left side of axial image)
    3 = LeftLung
    Background = 0

Usage:
    python generate_lung_mask.py -i ct.nrrd -o lung_mask.nrrd
"""

import argparse
import numpy as np
import SimpleITK as sitk
from scipy import ndimage


# CIP label map encoding
REGION_UNDEFINED  = 0
REGION_WHOLE_LUNG = 1
REGION_RIGHT_LUNG = 2
REGION_LEFT_LUNG  = 3
TYPE_UNDEFINED    = 0

def _encode(region: int, cip_type: int = TYPE_UNDEFINED) -> int:
    return int((cip_type << 8) | region)


def _threshold_lung(ct_arr: np.ndarray) -> np.ndarray:
    """
    Rough lung segmentation via HU threshold + morphological cleanup.
    Lung parenchyma: typically -950 to -300 HU.
    """
    # Threshold to candidate air/lung voxels
    air_mask = (ct_arr < -300) & (ct_arr > -1050)

    # Remove background air outside the body: largest connected component
    # is the patient body; invert to find body, then restrict to body interior.
    body = ct_arr > -700
    body = ndimage.binary_fill_holes(body)
    body = ndimage.binary_erosion(body, iterations=3)

    lung_candidate = air_mask & body

    # Keep only the two largest components (right and left lung)
    labeled, n_labels = ndimage.label(lung_candidate)
    if n_labels == 0:
        raise RuntimeError("No lung tissue detected — check HU range of CT")

    sizes = ndimage.sum(lung_candidate, labeled, range(1, n_labels + 1))
    top2  = np.argsort(sizes)[::-1][:2] + 1  # label indices (1-based)

    lung_mask = np.zeros_like(ct_arr, dtype=bool)
    for lbl in top2:
        lung_mask |= (labeled == lbl)

    # Fill holes within lung (per axial slice)
    for z in range(lung_mask.shape[0]):
        lung_mask[z] = ndimage.binary_fill_holes(lung_mask[z])

    return lung_mask


def _split_left_right(lung_mask: np.ndarray) -> np.ndarray:
    """
    Label voxels as RightLung (2) or LeftLung (3) based on patient left/right.
    In CT, patient right = image left = smaller x index.
    """
    labeled, n = ndimage.label(lung_mask)
    if n < 2:
        # Cannot split — label everything as WholeLung
        return lung_mask.astype(np.uint16) * _encode(REGION_WHOLE_LUNG)

    sizes = ndimage.sum(lung_mask, labeled, range(1, n + 1))
    top2 = np.argsort(sizes)[::-1][:2] + 1

    # Determine which component is on the right (smaller x centroid)
    centroids = ndimage.center_of_mass(lung_mask, labeled, top2)
    # centroids[i] = (z, y, x) centroid of top2[i]
    c0_x = centroids[0][2]
    c1_x = centroids[1][2]

    label_map = np.zeros_like(lung_mask, dtype=np.uint16)
    if c0_x < c1_x:
        # component top2[0] has smaller x → patient right
        label_map[labeled == top2[0]] = _encode(REGION_RIGHT_LUNG)
        label_map[labeled == top2[1]] = _encode(REGION_LEFT_LUNG)
    else:
        label_map[labeled == top2[0]] = _encode(REGION_LEFT_LUNG)
        label_map[labeled == top2[1]] = _encode(REGION_RIGHT_LUNG)

    return label_map


def generate_lung_mask(in_nrrd: str, out_nrrd: str) -> None:
    ct_img = sitk.ReadImage(in_nrrd)
    ct_arr = sitk.GetArrayFromImage(ct_img).astype(np.float32)  # (z, y, x)

    print("Segmenting lung...")
    lung_mask = _threshold_lung(ct_arr)

    print("Splitting into left/right lung...")
    label_arr = _split_left_right(lung_mask)

    out_img = sitk.GetImageFromArray(label_arr)
    out_img.CopyInformation(ct_img)
    out_img = sitk.Cast(out_img, sitk.sitkUInt16)
    sitk.WriteImage(out_img, out_nrrd)

    n_right = int(np.sum(label_arr == _encode(REGION_RIGHT_LUNG)))
    n_left  = int(np.sum(label_arr == _encode(REGION_LEFT_LUNG)))
    n_whole = int(np.sum(label_arr == _encode(REGION_WHOLE_LUNG)))
    print(f"RightLung voxels: {n_right}  LeftLung voxels: {n_left}  WholeLung: {n_whole}")

    # Sanity check: right and left lung centroids should be on opposite sides of midline
    if n_right > 0 and n_left > 0:
        x_size = label_arr.shape[2]
        right_xs = np.argwhere(label_arr == _encode(REGION_RIGHT_LUNG))[:, 2]
        left_xs  = np.argwhere(label_arr == _encode(REGION_LEFT_LUNG))[:, 2]
        right_cx = float(right_xs.mean())
        left_cx  = float(left_xs.mean())
        midline  = x_size / 2.0
        if (right_cx < midline) == (left_cx < midline):
            print("WARNING: RightLung and LeftLung centroids are on the same side of the "
                  "image midline. Left/right assignment may be incorrect for non-standard "
                  "patient orientation. This does not affect WholeLung processing.")
        else:
            print(f"Orientation check OK: RightLung centroid x={right_cx:.1f}, "
                  f"LeftLung centroid x={left_cx:.1f}, midline={midline:.1f}")

    print(f"Label map written to {out_nrrd}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate partial lung label map from CT")
    parser.add_argument("-i", dest="in_nrrd", required=True, help="Input CT nrrd")
    parser.add_argument("-o", dest="out_nrrd", required=True, help="Output label map nrrd")
    op = parser.parse_args()
    generate_lung_mask(op.in_nrrd, op.out_nrrd)
