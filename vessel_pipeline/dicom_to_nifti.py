#!/usr/bin/env python3
"""Convert a DICOM CT series directory to NIfTI (.nii.gz) for the CIP vessel pipeline.

Automatically selects the series with the most slices (the CT volume). Use
--list-series to inspect all series, and --series-index / --series-uid to override.

Usage:
  python dicom_to_nifti.py <dicom_dir> [output.nii.gz]
  python dicom_to_nifti.py <dicom_dir> --out /path/to/CT.nii.gz
  python dicom_to_nifti.py <dicom_dir> --list-series
  python dicom_to_nifti.py <dicom_dir> --series-index 1 /output/patient.nii.gz
"""

import argparse
import os
import sys
import tempfile

import SimpleITK as sitk


def find_series(dicom_dir):
    """Return [(uid, file_list), ...] sorted by slice count descending.

    Searches dicom_dir and subdirectories up to three levels deep (matching
    batch discovery for scanner layouts such as patient/study/series/*.dcm).
    """
    def _candidate_dirs(root, max_depth=3):
        root = os.path.abspath(root)
        yield root
        for current, dirs, _ in os.walk(root):
            rel = os.path.relpath(current, root)
            depth = 0 if rel == "." else rel.count(os.sep) + 1
            if depth >= max_depth:
                dirs[:] = []
                continue
            for dirname in sorted(dirs):
                yield os.path.join(current, dirname)

    def _collect(d):
        uids = sitk.ImageSeriesReader.GetGDCMSeriesIDs(d)
        result = []
        for uid in uids:
            files = sitk.ImageSeriesReader.GetGDCMSeriesFileNames(d, uid)
            if files:
                result.append((uid, list(files)))
        return result

    series_by_uid = {}
    for candidate_dir in _candidate_dirs(dicom_dir):
        for uid, files in _collect(candidate_dir):
            series_by_uid.setdefault(uid, []).extend(files)
    series = list(series_by_uid.items())

    if not series:
        raise RuntimeError(f"No DICOM series found in: {dicom_dir}")

    series.sort(key=lambda x: len(x[1]), reverse=True)
    return series


def convert(dicom_dir, output_path=None, series_index=0, series_uid=None, list_only=False):
    dicom_dir = os.path.abspath(dicom_dir)
    if not os.path.isdir(dicom_dir):
        raise RuntimeError(f"Not a directory: {dicom_dir}")

    series = find_series(dicom_dir)

    if list_only or len(series) > 1:
        print(f"Found {len(series)} series in {dicom_dir}:")
        for i, (uid, files) in enumerate(series):
            if list_only:
                tag = ""
            elif series_uid is not None:
                tag = " <-- will use" if uid == series_uid else ""
            else:
                tag = " <-- will use" if i == series_index else ""
            print(f"  [{i}] {uid}  ({len(files)} slices){tag}")
        if list_only:
            return None

    if series_uid is not None:
        match = [(u, f) for u, f in series if u == series_uid]
        if not match:
            raise RuntimeError(f"Series UID not found: {series_uid}")
        uid, files = match[0]
    else:
        if series_index >= len(series):
            raise RuntimeError(
                f"--series-index {series_index} out of range (0-{len(series) - 1})"
            )
        uid, files = series[series_index]

    print(f"Reading series [{series_index}]: {uid}  ({len(files)} slices)")

    reader = sitk.ImageSeriesReader()
    reader.SetFileNames(files)
    img = reader.Execute()
    img = sitk.Cast(img, sitk.sitkInt16)

    sz = img.GetSize()
    sp = img.GetSpacing()
    print(
        f"  size=({sz[0]}, {sz[1]}, {sz[2]})  "
        f"spacing=({sp[0]:.4f}, {sp[1]:.4f}, {sp[2]:.4f}) mm"
    )

    if output_path is None:
        output_path = os.path.join(dicom_dir, "CT.nii.gz")
    output_path = os.path.abspath(output_path)

    out_dir = os.path.dirname(output_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    if os.path.exists(output_path) and os.path.getsize(output_path) > 0:
        raise RuntimeError(f"Output already exists: {output_path}")

    fd, tmp_output = tempfile.mkstemp(
        prefix=f".{os.path.basename(output_path)}.",
        suffix=".tmp.nii.gz",
        dir=out_dir or ".",
    )
    os.close(fd)
    try:
        sitk.WriteImage(img, tmp_output)
        os.replace(tmp_output, output_path)
    except Exception:
        try:
            os.unlink(tmp_output)
        except OSError:
            pass
        raise
    print(f"Written: {output_path}")
    return output_path


def main():
    p = argparse.ArgumentParser(
        description="Convert a DICOM CT series directory to NIfTI (.nii.gz) for the CIP pipeline.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Auto-select largest series, write CT.nii.gz into the DICOM directory:
  python dicom_to_nifti.py /data/patient001/

  # Write to a specific output path:
  python dicom_to_nifti.py /data/patient001/ /output/patient001.nii.gz

  # Inspect all series, then pick a specific one:
  python dicom_to_nifti.py /data/patient001/ --list-series
  python dicom_to_nifti.py /data/patient001/ --series-index 1 /output/patient001.nii.gz
  python dicom_to_nifti.py /data/patient001/ --series-uid 1.2.840.10008.5.1.4.1.1.2
""",
    )
    p.add_argument(
        "dicom_dir",
        help="Directory containing DICOM files (subdirectories up to three levels deep are also searched)",
    )
    p.add_argument(
        "output",
        nargs="?",
        help="Output .nii.gz path (default: <dicom_dir>/CT.nii.gz)",
    )
    p.add_argument(
        "--out",
        dest="out_flag",
        metavar="PATH",
        help="Output path (alternative to positional argument)",
    )
    p.add_argument(
        "--series-index",
        type=int,
        default=0,
        metavar="N",
        help="Index of series to convert when multiple are present (default: 0 = most slices)",
    )
    p.add_argument(
        "--series-uid",
        metavar="UID",
        help="Select series by DICOM Series Instance UID",
    )
    p.add_argument(
        "--list-series",
        action="store_true",
        help="List all series found in the directory and exit without converting",
    )
    args = p.parse_args()

    output = args.out_flag or args.output

    try:
        convert(
            args.dicom_dir,
            output_path=output,
            series_index=args.series_index,
            series_uid=args.series_uid,
            list_only=args.list_series,
        )
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
