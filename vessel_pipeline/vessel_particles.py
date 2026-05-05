#!/usr/bin/env python3
"""
Standalone vessel particle pipeline.
Replaces Scripts/cip_compute_vessel_particles.py and all CIP/ITK-tools binary
calls with pure Python equivalents (SimpleITK, scipy, scikit-image).

Still requires Teem binaries on PATH: unu, puller, gprobe
(built via setup.sh).

Supported --init modes:
    Threshold   (default, recommended) — CT intensity threshold
    Frangi      — Frangi vesselness filter (requires scikit-image)
    VesselMask  — external binary vessel mask provided via --vmask
    StrainEnergy — NOT IMPLEMENTED; raises ValueError at startup

Usage (mirrors the original script):
    python vessel_particles.py -i ct.nrrd -l lung_mask.nrrd
        -o /out/case1 --tmpDir /tmp/vp -r WholeLung
        --init Threshold --liveTh -90 --seedTh -70
"""

import argparse
import os
import shlex
import shutil
import subprocess
import sys

import numpy as np
import nrrd
import SimpleITK as sitk
from scipy import ndimage

try:
    from skimage.morphology import skeletonize as skeletonize_3d
    HAS_SKIMAGE = True
except ImportError:
    HAS_SKIMAGE = False

try:
    from skimage.filters import frangi as skimage_frangi
    HAS_FRANGI = True
except ImportError:
    HAS_FRANGI = False


# ======================================================================
# Utility: write SimpleITK image with metadata preserved
# ======================================================================

def _write_sitk(arr: np.ndarray, ref_img: sitk.Image, path: str,
                pixel_type=None) -> None:
    img = sitk.GetImageFromArray(arr)
    img.SetSpacing(ref_img.GetSpacing())
    img.SetOrigin(ref_img.GetOrigin())
    img.SetDirection(ref_img.GetDirection())
    if pixel_type is not None:
        img = sitk.Cast(img, pixel_type)
    sitk.WriteImage(img, path)


# ======================================================================
# Region-code lookup (mirrors CIP ChestConventions region hierarchy)
# ======================================================================

# Map region name → set of lower-byte codes to keep.
# An empty set means "keep all non-zero" (WholeLung = parent of everything).
_REGION_KEEP_CODES: dict[str, set[int]] = {
    "WholeLung":          set(),         # keep all non-zero regions
    "RightLung":          {2, 4, 5, 6},  # RightLung + right lobes
    "LeftLung":           {3, 7, 8},     # LeftLung + left lobes
    "RightSuperiorLobe":  {4},
    "RightMiddleLobe":    {5},
    "RightInferiorLobe":  {6},
    "LeftSuperiorLobe":   {7},
    "LeftInferiorLobe":   {8},
}


def _region_keep_codes(region: str) -> set[int]:
    """Return set of lower-byte CIP region codes to keep (empty = all non-zero)."""
    codes = _REGION_KEEP_CODES.get(region)
    if codes is None:
        raise ValueError(
            f"Unknown region '{region}'. Known: {list(_REGION_KEEP_CODES)}"
        )
    return codes


def _region_mask(lm_arr: np.ndarray, region: str) -> np.ndarray:
    """Boolean mask of voxels matching the requested CIP region (or its children)."""
    codes = _region_keep_codes(region)
    lower = (lm_arr & 0xff).astype(np.uint16)
    if codes:
        return np.isin(lower, list(codes))
    return lower > 0


# ======================================================================
# CropLung replacement
# Replaces: CropLung --cipr <region> -m 0 -v -1000 --ict ... --ilm ...
# ======================================================================

def crop_lung(ct_path: str, lm_path: str, ct_out: str, lm_out: str,
              region: str = "WholeLung", fill_ct: int = -1000) -> None:
    """
    Crop CT and label map to bounding box of the requested lung region.
    Outside the bounding box: CT → fill_ct, LM → 0.
    Voxels inside the bounding box but not matching the region are also zeroed.
    """
    lm  = sitk.ReadImage(lm_path)
    lm_arr = sitk.GetArrayFromImage(lm).astype(np.uint16)  # (z, y, x)

    lung_mask = _region_mask(lm_arr, region)
    if not np.any(lung_mask):
        raise RuntimeError(
            f"No voxels matching region '{region}' in {lm_path}"
        )

    coords = np.argwhere(lung_mask)       # each row: (z, y, x)
    mn = coords.min(axis=0)               # (z0, y0, x0)
    mx = coords.max(axis=0)              # (z1, y1, x1)

    # SimpleITK RegionOfInterest uses (x, y, z) ordering
    sitk_index = [int(mn[2]), int(mn[1]), int(mn[0])]
    sitk_size  = [int(mx[2] - mn[2] + 1),
                  int(mx[1] - mn[1] + 1),
                  int(mx[0] - mn[0] + 1)]

    ct  = sitk.ReadImage(ct_path)
    ct_crop = sitk.RegionOfInterest(ct,  sitk_size, sitk_index)
    lm_crop = sitk.RegionOfInterest(lm,  sitk_size, sitk_index)

    ct_arr2 = sitk.GetArrayFromImage(ct_crop).copy()
    lm_arr2 = sitk.GetArrayFromImage(lm_crop).astype(np.uint16).copy()

    outside = ~_region_mask(lm_arr2, region)
    ct_arr2[outside] = fill_ct
    lm_arr2[outside] = 0

    _write_sitk(ct_arr2.astype(np.int16), ct_crop, ct_out, sitk.sitkInt16)
    _write_sitk(lm_arr2,                  lm_crop, lm_out, sitk.sitkUInt16)


# ======================================================================
# ExtractChestLabelMap replacement
# Replaces: ExtractChestLabelMap -r WholeLung -i <in> -o <out>
# ======================================================================

def extract_chest_label_map(lm_path: str, lm_out: str,
                            region: str = "WholeLung") -> None:
    """
    Zero out voxels not belonging to the requested CIP region (or its children).
    Equivalent to: ExtractChestLabelMap -r <region> -i <in> -o <out>
    """
    lm  = sitk.ReadImage(lm_path)
    arr = sitk.GetArrayFromImage(lm).astype(np.uint16)
    arr[~_region_mask(arr, region)] = 0
    _write_sitk(arr, lm, lm_out, sitk.sitkUInt16)


# ======================================================================
# Distance transform (replaces pxdistancetransform from ITK-tools)
# ======================================================================

def distance_transform(binary_mask_path: str, dist_out_path: str) -> None:
    """
    Euclidean distance transform of the binary mask foreground.
    Output: positive values inside, 0 on boundary, negative outside.
    Replaces: pxdistancetransform -in <mask> -out <dist>
    """
    lm      = sitk.ReadImage(binary_mask_path)
    arr     = sitk.GetArrayFromImage(lm)          # (z, y, x)
    spacing = lm.GetSpacing()                     # (sx, sy, sz) in mm

    binary  = (arr > 0)
    # scipy distance_transform_edt sampling order matches numpy (z, y, x)
    sampling = (spacing[2], spacing[1], spacing[0])

    # inside distance (positive)
    dist_inside  = ndimage.distance_transform_edt(binary,  sampling=sampling)
    # outside distance (positive, we negate it)
    dist_outside = ndimage.distance_transform_edt(~binary, sampling=sampling)

    # signed distance: positive inside lung, negative outside
    dist = dist_inside - dist_outside

    _write_sitk(dist.astype(np.float32), lm, dist_out_path)


# ======================================================================
# Binary thinning (replaces GenerateBinaryThinning3D)
# ======================================================================

def skeletonize_mask(mask_path: str, mask_out: str) -> None:
    """
    3D binary thinning of a binary mask.
    Replaces: GenerateBinaryThinning3D -i <in> -o <out>
    """
    if not HAS_SKIMAGE:
        raise ImportError(
            "scikit-image is required for skeletonize_mask. "
            "Install with: pip install scikit-image"
        )
    img = sitk.ReadImage(mask_path)
    arr = sitk.GetArrayFromImage(img)
    skel = skeletonize_3d(arr.astype(bool)).astype(np.int16)
    _write_sitk(skel, img, mask_out, sitk.sitkInt16)


# ======================================================================
# Frangi vesselness (replaces ComputeFeatureStrength -m Frangi)
# ======================================================================

def compute_frangi(ct_path: str, feat_out: str,
                   min_scale: float = 0.7, max_scale: float = 4.0,
                   num_scales: int = 7,
                   alpha: float = 0.63, beta: float = 0.51,
                   gamma: float = 245.0) -> None:
    """
    Frangi vesselness filter.
    Replaces: ComputeFeatureStrength -m Frangi -f RidgeLine
    """
    if not HAS_FRANGI:
        raise ImportError(
            "scikit-image is required for Frangi mode. "
            "Install with: pip install scikit-image"
        )
    img = sitk.ReadImage(ct_path)
    arr = sitk.GetArrayFromImage(img).astype(np.float32)
    sigmas = np.linspace(min_scale, max_scale, num_scales)
    feat = skimage_frangi(arr, sigmas=sigmas, alpha=alpha, beta=beta,
                          gamma=gamma, black_ridges=False)
    _write_sitk(feat.astype(np.float32), img, feat_out)


# ======================================================================
# Seed mask builders
# ======================================================================

def _make_seed_mask_threshold(ct_path: str, dist_arr: np.ndarray,
                               dist_threshold: float, intensity_th: float,
                               ref_img: sitk.Image, mask_out: str) -> None:
    """
    Simple threshold: seed = (CT > intensity_th) AND (dist > |dist_threshold|).
    The signed distance is positive inside the lung; dist_threshold is -2.0,
    so we keep voxels that are more than 2 mm from the wall.
    """
    ct_arr = sitk.GetArrayFromImage(sitk.ReadImage(ct_path)).astype(np.float32)
    inside = dist_arr > abs(dist_threshold)         # > 2 mm from wall
    seed   = ((ct_arr > intensity_th) & inside).astype(np.int16)
    _write_sitk(seed, ref_img, mask_out, sitk.sitkInt16)


def _make_seed_mask_frangi(ct_path: str, dist_arr: np.ndarray,
                            dist_threshold: float, vesselness_th: float,
                            min_scale: float, max_scale: float,
                            feat_path: str, ref_img: sitk.Image,
                            mask_out: str) -> None:
    """
    Frangi-based seed mask with approximate histogram equalization.
    Replaces the unu 2op x | unu heq | unu 2op gt | unu convert pipeline.
    """
    compute_frangi(ct_path, feat_path, min_scale, max_scale)

    feat_img = sitk.ReadImage(feat_path)
    feat_arr = sitk.GetArrayFromImage(feat_img).astype(np.float32)

    # Mask by lung interior (distance peeling)
    inside = dist_arr > abs(dist_threshold)
    feat_arr *= inside.astype(np.float32)

    # Approximate unu heq: percentile-based normalization over non-zero voxels
    pos_vals = feat_arr[feat_arr > 0]
    if pos_vals.size > 0:
        p_low  = np.percentile(pos_vals, 2.0)
        p_high = np.percentile(pos_vals, 98.0)
        denom  = max(p_high - p_low, 1e-10)
        feat_norm = np.clip((feat_arr - p_low) / denom, 0.0, 1.0)
    else:
        feat_norm = feat_arr

    seed = ((feat_norm > vesselness_th) & inside).astype(np.int16)
    _write_sitk(seed, ref_img, mask_out, sitk.sitkInt16)


# ======================================================================
# Deconvolution — calls unu (Teem) because the C4 inverse kernel is
# Teem-specific. unu is always available since we build Teem anyway.
# ======================================================================

def _deconvolve_unu(in_vol: str, out_vol: str,
                    min_intensity: float, max_intensity: float) -> None:
    """
    Clamp CT and apply B-spline C4 inverse kernel for scale-space prefiltering.
    Uses unu (Teem) because the c4hai kernel has no scipy equivalent.
    """
    cmd1 = ["unu", "3op", "clamp", str(min_intensity), in_vol, str(max_intensity)]
    cmd2 = ["unu", "resample", "-s", "x1", "x1", "x1",
            "-k", "c4hai", "-t", "float", "-o", out_vol]
    p1 = subprocess.Popen(cmd1, stdout=subprocess.PIPE)
    p2 = subprocess.Popen(cmd2, stdin=p1.stdout)
    p1.stdout.close()
    rc2 = p2.wait()
    rc1 = p1.wait()
    if rc1 != 0:
        raise subprocess.CalledProcessError(rc1, cmd1)
    if rc2 != 0:
        raise subprocess.CalledProcessError(rc2, cmd2)


def _downsample_unu(in_vol: str, out_vol: str, rate: float,
                    kernel: str = "cubic:0,0.5") -> None:
    val = 1.0 / rate
    cmd = ["unu", "resample",
           "-s", f"x{val:.6f}", f"x{val:.6f}", f"x{val:.6f}",
           "-k", kernel, "-i", in_vol, "-o", out_vol]
    subprocess.run(cmd, check=True)


# ======================================================================
# Puller parameter builders
# (logic extracted from ChestParticles / VesselParticles in cip_python)
# ======================================================================

# VesselParticles per-phase defaults (from cip_python/particles/vessel_particles.py)
_PHASES = {
    "iterations":  [100, 10,   75],
    "irads":       [1.5, 1.15, 0.8],
    "srads":       [1.2, 2,    4],
    "pcp":         [6,   20,   17],   # population control period
    "alphas":      [1.0, 0.35, 0.84],
    "betas":       [0.77, 0.75, 0.57],
    "gammas":      [0.37, 0.53, 0.57],
}

_MODE_THRESH = -0.3
_BINNING_WIDTH = 1.3
_RECON_KERNEL  = "-k00 c4h -k11 c4hd -k22 c4hdd -kssr hermite -kssb ds:1,5"


def _vol_params(sp_in: str, mask: str | None,
                scale_samples: int, max_scale: float) -> str:
    p = (f' -vol "{sp_in}":scalar:0-{scale_samples}-{max_scale}-o:V'
         f' "{sp_in}":scalar:0-{scale_samples}-{max_scale}-on:VSN')
    if mask:
        p += f' "{mask}":scalar:M'
    return p


def _info_params(scale_samples: int, seed_thresh: float, live_thresh: float,
                 use_mode_thresh: bool, use_mask: bool) -> str:
    tag = "VSN"
    p = (" -info h-c:V:val:0:-1 hgvec:V:gvec"
         " hhess:V:hess tan1:V:hevec1 tan2:V:hevec2 ")
    p += f"sthr:{tag}:heval1:{seed_thresh}:-1 "
    p += f"lthr:{tag}:heval1:{live_thresh}:-1 "
    p += f"strn:{tag}:heval1:0:-1 "
    if use_mode_thresh:
        p += f"lthr2:{tag}:hmode:{_MODE_THRESH}:1 "
    if use_mask:
        p += "spthr:M:val:0.5:1"
    return p


def _optimizer_params(pcp: int) -> str:
    return (f"-pcp {pcp} -edpcmin 0.1 -edmin 0.0000001"
            f" -eip 0.00001 -ess 0.5 -oss 2.0 -step 1 -maxci 10"
            f" -rng 45 -bws {_BINNING_WIDTH}")


def _energy_params(use_strength: bool, energy_type: str,
                   irad: float, srad: float,
                   alpha: float, beta: float, gamma: float) -> str:
    return (f"-enr qwell:0.7 -ens bparab:10,0.7,-0.00 -enw butter:10,0.7"
            f" -efs {str(use_strength).lower()}"
            f" -int {energy_type}"
            f" -irad {irad} -srad {srad}"
            f" -alpha {alpha} -beta {beta} -gamma {gamma}")


def _misc_params(verbose: int, scale_samples: int) -> str:
    v = max(0, verbose - 1)
    p = f"-nave true -v {v} -pbm 0"
    if scale_samples > 1:
        p += " -bsp bleed"
    return p


def _run_puller(tmp_dir: str, vol_p: str, misc_p: str, info_p: str,
                enr_p: str, init_p: str, opt_p: str,
                out_file: str, iterations: int) -> None:
    cmd = (f'puller -sscp "{tmp_dir}" -cbst true'
           f' {vol_p} {misc_p} {info_p} {enr_p}'
           f' {init_p} {_RECON_KERNEL} {opt_p}'
           f' -o "{out_file}" -maxi {iterations}')
    subprocess.run(shlex.split(cmd), check=True)


# ======================================================================
# gprobe: probe quantities at particle positions
# ======================================================================

# Map: gprobe quantity name → (vtk array name, use_normalized_derivs)
# Matches ChestParticles._probing_quantities from cip_python
_PROBING_QUANTITIES = {
    "val":    ("val",    False),
    "heval0": ("h0",     True),
    "heval1": ("h1",     True),
    "heval2": ("h2",     True),
    "hmode":  ("hmode",  True),
    "hevec0": ("hevec0", False),
    "hevec1": ("hevec1", False),
    "hevec2": ("hevec2", False),
    "hess":   ("hess",   False),
}


def _probe_quantity(in_volume: str, in_particles: str, quantity: str,
                    out_nrrd: str, tmp_dir: str,
                    scale_samples: int, max_scale: float,
                    normalized_derivs: bool, verbose: int) -> None:
    ssf_pattern = os.path.join(tmp_dir, f"V-%03u-{scale_samples:03d}.nrrd")
    cmd = (f'gprobe -i "{in_volume}" -k scalar {_RECON_KERNEL}'
           f' -pi "{in_particles}" -q {quantity} -v 0 -o "{out_nrrd}"'
           f' -ssn {scale_samples} -sso -ssr 0 {int(max_scale):03d}'
           f' -ssf "{ssf_pattern}"')
    if normalized_derivs:
        cmd += " -ssnd"
    subprocess.run(shlex.split(cmd), check=True)


# ======================================================================
# Full 3-pass vessel particle system
# ======================================================================

def run_vessel_particles(
    ct_region: str,
    mask_region: str | None,
    tmp_dir: str,
    live_thresh: float,
    seed_thresh: float,
    max_scale: float = 6.0,
    scale_samples: int = 10,
    min_intensity: float = -950.0,
    max_intensity: float = 200.0,
    verbose: int = 0,
) -> tuple[str, str]:
    """
    Run 3-pass vessel particle optimization (puller) then probe (gprobe).

    Returns:
        (final_particles_nrrd, sp_in_file) — paths consumed by nrrds_to_vtk
    """
    # Deconvolve CT for scale-space processing
    sp_in = os.path.join(tmp_dir, "ct-deconv.nrrd")
    _deconvolve_unu(ct_region, sp_in, min_intensity, max_intensity)

    pass_file = os.path.join(tmp_dir, "pass%d.nrrd")

    # --- Pass 1: PerVoxel initialization, uniform energy -----------------
    use_mask_p1 = mask_region is not None
    vp1   = _vol_params(sp_in, mask_region, scale_samples, max_scale)
    ip1   = _info_params(scale_samples, seed_thresh, live_thresh, False, use_mask_p1)
    op1   = _optimizer_params(_PHASES["pcp"][0])
    ep1   = _energy_params(False, "uni",
                           _PHASES["irads"][0], _PHASES["srads"][0],
                           _PHASES["alphas"][0], _PHASES["betas"][0],
                           _PHASES["gammas"][0])
    init1 = f"-ppv 2 -nss 2 -jit 1"
    misc1 = _misc_params(verbose, scale_samples)
    _run_puller(tmp_dir, vp1, misc1, ip1, ep1, init1, op1,
                pass_file % 1, _PHASES["iterations"][0])

    # --- Pass 2: from pass1, add scale+spatial energy --------------------
    vp2   = _vol_params(sp_in, None, scale_samples, max_scale)
    ip2   = _info_params(scale_samples, seed_thresh, live_thresh, False, False)
    op2   = _optimizer_params(_PHASES["pcp"][1])
    ep2   = _energy_params(True, "add",
                           _PHASES["irads"][1], _PHASES["srads"][1],
                           _PHASES["alphas"][1], _PHASES["betas"][1],
                           _PHASES["gammas"][1])
    init2 = f'-pi "{pass_file % 1}"'
    misc2 = _misc_params(verbose, scale_samples)
    _run_puller(tmp_dir, vp2, misc2, ip2, ep2, init2, op2,
                pass_file % 2, _PHASES["iterations"][1])

    # --- Pass 3: from pass2, mode threshold active -----------------------
    vp3   = _vol_params(sp_in, None, scale_samples, max_scale)
    ip3   = _info_params(scale_samples, seed_thresh, live_thresh, True, False)
    op3   = _optimizer_params(_PHASES["pcp"][2])
    ep3   = _energy_params(True, "add",
                           _PHASES["irads"][2], _PHASES["srads"][2],
                           _PHASES["alphas"][2], _PHASES["betas"][2],
                           _PHASES["gammas"][2])
    init3 = f'-pi "{pass_file % 2}"'
    misc3 = _misc_params(verbose, scale_samples)
    _run_puller(tmp_dir, vp3, misc3, ip3, ep3, init3, op3,
                pass_file % 3, _PHASES["iterations"][2])

    # --- Probe quantities at pass3 particle positions -------------------
    for qty, (vtk_name, normalized) in _PROBING_QUANTITIES.items():
        out_nrrd = os.path.join(tmp_dir, f"{qty}.nrrd")
        _probe_quantity(sp_in, pass_file % 3, qty, out_nrrd, tmp_dir,
                        scale_samples, max_scale, normalized, verbose)

    return pass_file % 3, sp_in


# ======================================================================
# nrrds_to_vtk: ReadNRRDsWriteVTK replacement
# ======================================================================

# CIP encoding: Vessel type = 3, UndefinedRegion = 0
# ChestRegionChestType = (type << 8) | region = (3 << 8) | 0 = 768
_CRCT_VESSEL_UNDEFINED_REGION = float((3 << 8) | 0)


def nrrds_to_vtk(
    particles_nrrd: str,
    tmp_dir: str,
    out_vtk: str,
    irad: float,
    srad: float,
    live_thresh: float,
    seed_thresh: float,
    spacing: tuple,
    cip_region: str = "UndefinedRegion",
    cip_type: str = "Vessel",
) -> None:
    """
    Assemble VTK PolyData from particle nrrd + probed quantity nrrds.
    Exact replacement for ReadNRRDsWriteVTK C++ tool.

    The particles nrrd has shape (4, N): rows are x, y, z, scale.
    Each probed quantity nrrd has shape (ncomp, N).
    """
    import vtk
    from vtk.util.numpy_support import numpy_to_vtk

    # -- Load particles (4 x N) ------------------------------------------
    particles, _ = nrrd.read(particles_nrrd)
    if particles.ndim == 2 and particles.shape[0] == 4:
        xyz   = particles[:3, :].T.astype(np.float32)  # (N, 3)
        scale = particles[3, :].astype(np.float32)      # (N,)
    else:
        raise ValueError(
            f"Expected particle nrrd shape (4, N), got {particles.shape}"
        )
    num_pts = xyz.shape[0]

    # -- Build PolyData ---------------------------------------------------
    poly = vtk.vtkPolyData()

    pts = vtk.vtkPoints()
    pts.SetData(numpy_to_vtk(xyz, deep=True))
    poly.SetPoints(pts)

    # scale array (1-component point data)
    sc_arr = vtk.vtkFloatArray()
    sc_arr.SetName("scale")
    sc_arr.SetNumberOfComponents(1)
    sc_arr.SetNumberOfTuples(num_pts)
    for i, v in enumerate(scale.tolist()):
        sc_arr.SetValue(i, v)
    poly.GetPointData().AddArray(sc_arr)

    # -- Add probed quantity arrays ---------------------------------------
    for qty, (vtk_name, _) in _PROBING_QUANTITIES.items():
        nrrd_path = os.path.join(tmp_dir, f"{qty}.nrrd")
        if not os.path.exists(nrrd_path):
            print(f"Warning: {nrrd_path} not found; skipping {vtk_name}")
            continue

        data, _ = nrrd.read(nrrd_path)
        if data.ndim == 1:
            data = data.reshape(1, -1)
        ncomp = data.shape[0]

        arr = vtk.vtkFloatArray()
        arr.SetName(vtk_name)
        arr.SetNumberOfComponents(ncomp)
        arr.SetNumberOfTuples(num_pts)

        for j in range(num_pts):
            if ncomp == 1:
                arr.SetValue(j, float(data[0, j]))
            else:
                tup = [float(data[c, j]) for c in range(ncomp)]
                arr.SetTuple(j, tup)

        poly.GetPointData().AddArray(arr)

    # -- ChestRegionChestType --------------------------------------------
    # Try CIP Python conventions; fall back to hardcoded Vessel value
    crct_value = _CRCT_VESSEL_UNDEFINED_REGION
    try:
        import sys as _sys
        _repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        if _repo not in _sys.path:
            _sys.path.insert(0, _repo)
        from cip_python.common import ChestConventions
        c = ChestConventions()
        rv = c.GetChestRegionValueFromName(cip_region)
        tv = c.GetChestTypeValueFromName(cip_type)
        crct_value = float(c.GetValueFromChestRegionAndType(rv, tv))
    except Exception:
        pass  # use hardcoded fallback

    crct_arr = vtk.vtkFloatArray()
    crct_arr.SetName("ChestRegionChestType")
    crct_arr.SetNumberOfComponents(1)
    crct_arr.SetNumberOfTuples(num_pts)
    for i in range(num_pts):
        crct_arr.SetValue(i, crct_value)
    poly.GetPointData().AddArray(crct_arr)

    # -- Field data: metadata --------------------------------------------
    def _add_field_scalar(name: str, value: float) -> None:
        fa = vtk.vtkFloatArray()
        fa.SetName(name)
        fa.SetNumberOfComponents(1)
        fa.SetNumberOfTuples(1)
        fa.SetValue(0, float(value))
        poly.GetFieldData().AddArray(fa)

    _add_field_scalar("irad",   irad)
    _add_field_scalar("srad",   srad)
    _add_field_scalar("liveth", live_thresh)
    _add_field_scalar("seedth", seed_thresh)

    sp_arr = vtk.vtkFloatArray()
    sp_arr.SetName("spacing")
    sp_arr.SetNumberOfComponents(3)
    sp_arr.SetNumberOfTuples(1)
    sp_arr.SetComponent(0, 0, float(spacing[0]))
    sp_arr.SetComponent(0, 1, float(spacing[1]))
    sp_arr.SetComponent(0, 2, float(spacing[2]))
    poly.GetFieldData().AddArray(sp_arr)

    # -- Vertices (required for polydata particle format) ----------------
    cell_arr = vtk.vtkCellArray()
    for pid in range(num_pts):
        v = vtk.vtkVertex()
        v.GetPointIds().SetId(0, pid)
        cell_arr.InsertNextCell(v)
    poly.SetVerts(cell_arr)

    # -- Write -----------------------------------------------------------
    writer = vtk.vtkPolyDataWriter()
    writer.SetFileName(out_vtk)
    writer.SetInputData(poly)
    writer.SetFileTypeToBinary()
    writer.Write()
    print(f"VTK written: {out_vtk}  ({num_pts} particles)")


# ======================================================================
# Main pipeline
# ======================================================================

class VesselParticlesPipeline:
    def __init__(
        self,
        ct_file: str,
        lm_file: str,
        regions: list[str],
        tmp_dir: str,
        output_prefix: str,
        init_method: str = "Threshold",
        vessel_mask: str | None = None,
        resampling_method: str = "Linear",
        lth: float = -90.0,
        sth: float = -70.0,
        voxel_size: float = 0.0,
        min_scale: float = 0.7,
        max_scale_frangi: float = 4.0,
        vesselness_th: float = 0.38,
        multires: bool = False,
        justparticles: bool = False,
        clean_cache: bool = False,
        verbose: int = 0,
    ) -> None:
        if init_method == "StrainEnergy":
            raise ValueError(
                "StrainEnergy init is not implemented in this Python replacement. "
                "Use --init Threshold (default/recommended) or --init Frangi."
            )
        if init_method == "Frangi" and not HAS_FRANGI:
            raise ImportError(
                "scikit-image is required for Frangi mode. "
                "Run: pip install scikit-image"
            )

        self.ct_file         = ct_file
        self.lm_file         = lm_file
        self.regions         = regions
        self.tmp_dir         = tmp_dir
        self.output_prefix   = output_prefix
        self.init_method     = init_method
        self.vessel_mask     = vessel_mask
        self.resampling_method = resampling_method
        self.lth             = lth
        self.sth             = sth
        self.voxel_size      = voxel_size
        self.min_scale       = min_scale
        self.max_scale_frangi = max_scale_frangi
        self.vesselness_th   = vesselness_th
        self.multires        = multires
        self.justparticles   = justparticles
        self.clean_cache     = clean_cache
        self.verbose         = verbose

        self.distance_from_wall = -2.0   # mm; negative = inside lung
        self.intensity_th       = -700.0 # HU threshold for Threshold mode

        # Particle system parameters (VesselParticles defaults)
        self.max_scale_particles = 6.0
        self.scale_samples       = 10
        self.min_intensity_particles = -950.0
        self.max_intensity_particles =  200.0

        self.case_id = os.path.basename(ct_file).split(".")[0]

    def execute(self) -> None:
        os.makedirs(self.tmp_dir, exist_ok=True)

        ct_file = self.ct_file
        lm_file = self.lm_file

        # Optional: resample to isotropic voxel size
        if self.voxel_size > 0:
            ct_file, lm_file = self._resample_isotropic(ct_file, lm_file)

        for region in self.regions:
            print(f"\n--- Processing region: {region} ---")
            self._process_region(region, ct_file, lm_file)

    def _resample_isotropic(self, ct_file: str, lm_file: str) -> tuple[str, str]:
        ct_img  = sitk.ReadImage(ct_file)
        spacing = ct_img.GetSpacing()   # (sx, sy, sz)

        ct_out = os.path.join(self.tmp_dir, f"{self.case_id}_resample.nrrd")
        lm_out = os.path.join(self.tmp_dir,
                              f"{self.case_id}_resamplepartialLungLabelMap.nrrd")

        kernel_map = {
            "Linear":       "tent",
            "Cubic":        "cubic:0,0.5",
            "Registration": "tent",
            "Hybrid":       "cubic:0,0.5",
        }
        kernel = kernel_map.get(self.resampling_method, "tent")

        for src, dst, k in [
            (ct_file, ct_out, kernel),
            (lm_file, lm_out, "cheap"),
        ]:
            f0 = spacing[0] / self.voxel_size
            f1 = spacing[1] / self.voxel_size
            f2 = spacing[2] / self.voxel_size
            cmd = ["unu", "resample", "-k", k,
                   "-s", f"x{f0:.6f}", f"x{f1:.6f}", f"x{f2:.6f}",
                   "-i", src, "-o", dst, "-c", "cell"]
            subprocess.run(cmd, check=True)

        return ct_out, lm_out

    def _process_region(self, region: str, ct_file: str, lm_file: str) -> None:
        # "WholeLung" → "wholeLung" (first char lower-cased)
        rtag = region[0].lower() + region[1:]
        rdir = os.path.join(self.tmp_dir, rtag)
        os.makedirs(rdir, exist_ok=True)

        ct_region   = os.path.join(rdir, f"{self.case_id}_{rtag}.nrrd")
        lm_region   = os.path.join(rdir, f"{self.case_id}_{rtag}_partialLungLabelMap.nrrd")
        feat_region = os.path.join(rdir, f"{self.case_id}_{rtag}_featureMap.nrrd")
        mask_region = os.path.join(rdir, f"{self.case_id}_{rtag}_mask.nrrd")
        particles_out = f"{self.output_prefix}_{rtag}VesselParticles.vtk"

        if not self.justparticles:
            # 1. CropLung: crop to requested region bounding box
            print("  CropLung...")
            crop_lung(ct_file, lm_file, ct_region, lm_region, region=region)

            # 2. ExtractChestLabelMap: zero non-matching region voxels
            print("  ExtractChestLabelMap...")
            extract_chest_label_map(lm_region, lm_region, region=region)

            # 3. Binarize LM (unu 2op gt LM 0.5)
            lm_img  = sitk.ReadImage(lm_region)
            lm_arr  = sitk.GetArrayFromImage(lm_img).astype(np.float32)
            bin_arr = (lm_arr > 0.5).astype(np.int16)
            bin_path = os.path.join(rdir, "_bin_lung.nrrd")
            _write_sitk(bin_arr, lm_img, bin_path, sitk.sitkInt16)

            # 4. Distance transform (replaces pxdistancetransform)
            print("  Distance transform...")
            dist_path = os.path.join(rdir, "_dist.nrrd")
            distance_transform(bin_path, dist_path)
            dist_img  = sitk.ReadImage(dist_path)
            dist_arr  = sitk.GetArrayFromImage(dist_img).astype(np.float32)

            # 5. Build seed mask based on init method
            print(f"  Building seed mask ({self.init_method})...")
            ref_img = sitk.ReadImage(ct_region)

            if self.init_method == "Threshold":
                _make_seed_mask_threshold(
                    ct_region, dist_arr, self.distance_from_wall,
                    self.intensity_th, ref_img, mask_region
                )

            elif self.init_method == "Frangi":
                _make_seed_mask_frangi(
                    ct_region, dist_arr, self.distance_from_wall,
                    self.vesselness_th, self.min_scale, self.max_scale_frangi,
                    feat_region, ref_img, mask_region
                )

            elif self.init_method == "VesselMask":
                # Use provided vessel mask restricted to lung interior
                if self.vessel_mask:
                    vm_img  = sitk.ReadImage(self.vessel_mask)
                    vm_arr  = sitk.GetArrayFromImage(vm_img).astype(np.float32)
                    inside  = dist_arr > abs(self.distance_from_wall)
                    seed    = (vm_arr > 0) & inside
                    _write_sitk(seed.astype(np.int16), ref_img,
                                mask_region, sitk.sitkInt16)
                else:
                    # No external mask: fall back to threshold
                    _make_seed_mask_threshold(
                        ct_region, dist_arr, self.distance_from_wall,
                        self.intensity_th, ref_img, mask_region
                    )

            # 6. Skeletonize (replaces GenerateBinaryThinning3D)
            print("  Skeletonizing mask...")
            if not HAS_SKIMAGE:
                print("  Warning: scikit-image not available; skipping skeletonization")
            else:
                skeletonize_mask(mask_region, mask_region)

        # 7. Run particle system (puller + gprobe)
        print("  Running particle system (puller)...")
        final_particles, sp_in = run_vessel_particles(
            ct_region,
            mask_region if not self.justparticles else None,
            rdir,
            live_thresh=self.lth,
            seed_thresh=self.sth,
            max_scale=self.max_scale_particles,
            scale_samples=self.scale_samples,
            min_intensity=self.min_intensity_particles,
            max_intensity=self.max_intensity_particles,
            verbose=self.verbose,
        )

        # 8. Assemble VTK (replaces ReadNRRDsWriteVTK)
        print("  Assembling VTK...")
        sp_sitk = sitk.ReadImage(sp_in)
        spacing = sp_sitk.GetSpacing()   # (sx, sy, sz)

        nrrds_to_vtk(
            final_particles, rdir, particles_out,
            irad=_PHASES["irads"][2],
            srad=_PHASES["srads"][2],
            live_thresh=self.lth,
            seed_thresh=self.sth,
            spacing=spacing,
        )

        if self.clean_cache:
            shutil.rmtree(rdir)
            print(f"  Cleaned tmp dir: {rdir}")


# ======================================================================
# CLI entry point
# ======================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Vessel particle pipeline (Python replacement for "
                    "cip_compute_vessel_particles.py)"
    )
    parser.add_argument("-i",  dest="ct_file",     required=True,
                        help="Input CT nrrd file")
    parser.add_argument("-l",  dest="lm_file",     required=True,
                        help="Input partial lung label map nrrd file")
    parser.add_argument("-o",  dest="output_prefix", required=True,
                        help="Output prefix (e.g. /out/case1)")
    parser.add_argument("--tmpDir", dest="tmp_dir", required=True,
                        help="Temporary directory for intermediate files")
    parser.add_argument("-r",  dest="regions",     required=True,
                        help="Comma-separated region names, e.g. WholeLung")
    parser.add_argument("--liveTh",     dest="lth",          type=float, default=-90.0)
    parser.add_argument("--seedTh",     dest="sth",          type=float, default=-70.0)
    parser.add_argument("-s",           dest="voxel_size",   type=float, default=0.0,
                        help="Resample to this isotropic voxel size (mm); 0=no resample")
    parser.add_argument("--minscale",   dest="min_scale",    type=float, default=0.7)
    parser.add_argument("--maxscale",   dest="max_scale",    type=float, default=4.0)
    parser.add_argument("--init",       dest="init_method",  default="Threshold",
                        choices=["Threshold", "Frangi", "VesselMask", "StrainEnergy"])
    parser.add_argument("--vmask",      dest="vessel_mask",  default=None)
    parser.add_argument("--vesselness_th", dest="vesselness_th", type=float, default=0.38)
    parser.add_argument("--resampling", dest="resampling_method", default="Linear")
    parser.add_argument("--multires",   dest="multires",     action="store_true", default=False)
    parser.add_argument("--justparticles", dest="justparticles", action="store_true", default=False)
    parser.add_argument("--cleanCache", dest="clean_cache",  action="store_true", default=False)
    parser.add_argument("-v",           dest="verbose",      type=int, default=0)

    # Check Teem binaries are available
    for binary in ("unu", "puller", "gprobe"):
        if shutil.which(binary) is None:
            sys.exit(
                f"ERROR: '{binary}' not found on PATH. "
                "Build Teem with setup.sh and add its bin/ to PATH."
            )

    op = parser.parse_args()
    regions = [r.strip() for r in op.regions.split(",")]

    pipeline = VesselParticlesPipeline(
        ct_file=op.ct_file,
        lm_file=op.lm_file,
        regions=regions,
        tmp_dir=op.tmp_dir,
        output_prefix=op.output_prefix,
        init_method=op.init_method,
        vessel_mask=op.vessel_mask,
        resampling_method=op.resampling_method,
        lth=op.lth,
        sth=op.sth,
        voxel_size=op.voxel_size,
        min_scale=op.min_scale,
        max_scale_frangi=op.max_scale,
        vesselness_th=op.vesselness_th,
        multires=op.multires,
        justparticles=op.justparticles,
        clean_cache=op.clean_cache,
        verbose=op.verbose,
    )
    pipeline.execute()
