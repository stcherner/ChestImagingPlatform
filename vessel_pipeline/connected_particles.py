#!/usr/bin/env python3
"""
Compute minimum spanning tree topology on vessel (or airway) particles.
Replaces ReadParticlesWriteConnectedParticles (CIP CLI tool).

Reads a VTK polydata of particles, builds a weighted undirected graph where
edges connect particles within `distance_threshold` mm, weights by a
combined distance + orientation term, then extracts the MST (Kruskal) and
writes the result as VTK polydata with line cells representing MST edges.

Usage:
    python connected_particles.py -i particles.vtk -o connected.vtk
    python connected_particles.py -i particles.vtk -o connected.vtk --dist 3.0 --type airway
"""

import argparse
import numpy as np
import networkx as nx
import vtk
from scipy.spatial import cKDTree


_ANGLE_SIGMA = 1.0  # from CIP: edgeWeightAngleSigma


def _angle_between(v1: np.ndarray, v2: np.ndarray) -> float:
    """Absolute angle in degrees between two vectors (clamped to [0, 90])."""
    n1, n2 = np.linalg.norm(v1), np.linalg.norm(v2)
    if n1 == 0.0 or n2 == 0.0:
        return 0.0
    cos_a = np.clip(np.dot(v1, v2) / (n1 * n2), -1.0, 1.0)
    angle = float(np.degrees(np.arccos(cos_a)))
    return min(angle, 180.0 - angle)  # fold to [0, 90]


def _edge_weight(p1: np.ndarray, p2: np.ndarray,
                 hevec1: np.ndarray, hevec2: np.ndarray) -> float:
    """
    Weight = dist * (1 + exp(-((90 - min_angle) / sigma)^2))
    Mirrors CIP GetEdgeWeight. Lower weight = more axis-aligned connection.
    """
    conn = p1 - p2
    dist = float(np.linalg.norm(conn))
    a1 = _angle_between(hevec1, conn)
    a2 = _angle_between(hevec2, conn)
    angle = min(a1, a2)
    return dist * (1.0 + np.exp(-((90.0 - angle) / _ANGLE_SIGMA) ** 2))


def _read_poly(path: str) -> vtk.vtkPolyData:
    reader = vtk.vtkPolyDataReader()
    reader.SetFileName(path)
    reader.Update()
    return reader.GetOutput()


def _write_poly(poly: vtk.vtkPolyData, path: str) -> None:
    writer = vtk.vtkPolyDataWriter()
    writer.SetFileName(path)
    writer.SetInputData(poly)
    writer.SetFileTypeToBinary()
    writer.Write()


def connected_particles(in_vtk: str, out_vtk: str,
                        distance_threshold: float = 2.0,
                        particles_type: str = "vessel") -> None:
    poly = _read_poly(in_vtk)
    n = poly.GetNumberOfPoints()
    print(f"Particles: {n}")

    vec_name = "hevec0" if particles_type == "vessel" else "hevec2"
    hevec_arr = poly.GetPointData().GetArray(vec_name)
    if hevec_arr is None:
        raise RuntimeError(f"Point data array '{vec_name}' not found in {in_vtk}")

    pts = np.array([poly.GetPoint(i) for i in range(n)])
    hvecs = np.array([hevec_arr.GetTuple3(i) for i in range(n)])

    print(f"Building graph (threshold={distance_threshold} mm)...")
    G = nx.Graph()
    G.add_nodes_from(range(n))

    tree = cKDTree(pts)
    for i, j in tree.query_pairs(r=distance_threshold):
        w = _edge_weight(pts[i], pts[j], hvecs[i], hvecs[j])
        G.add_edge(i, j, weight=w)

    print(f"Graph edges: {G.number_of_edges()}")
    print("Computing minimum spanning tree (Kruskal)...")
    mst = nx.minimum_spanning_tree(G, algorithm="kruskal")
    print(f"MST edges: {mst.number_of_edges()}")

    # Build output polydata: same points + all point/field data + MST lines
    out_poly = vtk.vtkPolyData()
    out_poly.SetPoints(poly.GetPoints())

    pd = poly.GetPointData()
    for k in range(pd.GetNumberOfArrays()):
        out_poly.GetPointData().AddArray(pd.GetArray(k))

    fd = poly.GetFieldData()
    for k in range(fd.GetNumberOfArrays()):
        out_poly.GetFieldData().AddArray(fd.GetArray(k))

    lines = vtk.vtkCellArray()
    for u, v in mst.edges():
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, u)
        line.GetPointIds().SetId(1, v)
        lines.InsertNextCell(line)
    out_poly.SetLines(lines)

    _write_poly(out_poly, out_vtk)
    print(f"Written: {out_vtk}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="MST-connected vessel/airway particles (replaces ReadParticlesWriteConnectedParticles)")
    parser.add_argument("-i", dest="in_vtk", required=True,
                        help="Input particles VTK")
    parser.add_argument("-o", dest="out_vtk", required=True,
                        help="Output connected particles VTK")
    parser.add_argument("--dist", dest="distance_threshold", type=float,
                        default=2.0, help="Max inter-particle distance (mm, default: 2.0)")
    parser.add_argument("--type", dest="particles_type",
                        choices=["vessel", "airway"], default="vessel",
                        help="Particle type (default: vessel)")
    op = parser.parse_args()
    connected_particles(op.in_vtk, op.out_vtk, op.distance_threshold, op.particles_type)
