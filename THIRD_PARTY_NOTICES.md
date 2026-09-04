<!-- SPDX-License-Identifier: CC-BY-NC-ND-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Joseph Young -->

# Third-Party Notices

Components used by `maritime-edge`, their licenses, and which tree consumes
them. Versions should be reconciled against `requirements.txt` before any
public release.

Nothing in this file grants rights in the third-party components listed. Each
remains governed by its own license.

---

## Copyleft — consumed only under `scripts/analysis/`

| Component | License | Upstream |
|---|---|---|
| Ultralytics YOLO | AGPL-3.0-only | https://github.com/ultralytics/ultralytics |

**Position taken by this repository.** Ultralytics asserts that software
importing their package constitutes a combined work subject to the AGPL, and
sells a commercial license on that premise. Whether a Python `import` creates
a combined work under GPL-family copyleft is genuinely contested, and this
repository does not take a position on the merits. It adopts the conservative
reading: all code importing Ultralytics is isolated under `scripts/analysis/`
and licensed `AGPL-3.0-only`.

Verify Ultralytics' current licensing terms before public release — they may
have changed.

**AGPL §13.** Requires offering corresponding source to users interacting with
the software over a network. `scripts/analysis/` is not network-facing. If that
changes, §13 compliance becomes a live obligation.

---

## Permissive and proprietary — `scripts/` and `scripts/analysis/`

| Component | License | Notes |
|---|---|---|
| PyTorch | BSD-3-Clause | ONNX export on Jetson; training on SuperPOD |
| ONNX / ONNX Runtime | MIT | Parity checking against TensorRT engines |
| OpenCV (`opencv-python`) | Apache-2.0 | Version 4.5.0 onward. Earlier releases are BSD-3-Clause |
| NumPy | BSD-3-Clause | |
| NVIDIA TensorRT | NVIDIA proprietary (SLA) | **Not redistributable.** Do not vendor engines, `.plan` files, or TensorRT libraries into this repository |
| NVIDIA CUDA / cuDNN | NVIDIA proprietary (EULA) | Not redistributable |
| JetPack / L4T BSP | NVIDIA proprietary + assorted OSS | Not redistributable |
| GStreamer | LGPL-2.1-or-later | Invoked as an external process, not linked |
| v4l-utils (`v4l2-ctl`) | GPL-2.0-or-later | Invoked as an external process, not linked |
| WeasyPrint | BSD-3-Clause | Document generation, `docs/` |

GStreamer and `v4l2-ctl` are called as subprocesses. Process invocation does
not create a combined work, so their copyleft terms do not propagate to
`scripts/`.

Autodistill, GroundedDINO, and GroundedSAM are planned but not yet used. Add
entries with verified licenses before any of them enters `requirements.txt` —
GroundedDINO in particular carries dependencies with mixed terms that need
checking rather than assuming.

---

## Datasets

Derived annotations do not automatically become the author's to relicense.
Upstream terms travel with derived work.

| Dataset | Terms | Notes |
|---|---|---|
| SeaShips | Academic/research use, permission-gated | Shao et al. 2018. Confirm current terms with the maintainers before publishing anything derived from it |
| Singapore Maritime Dataset | Research use, attribution required | Prasad et al. Confirm redistribution terms for derived annotations |

**Do not commit images from either dataset to this repository.** Reference
them by download instruction. If derived annotations are committed, the file
must carry a comment naming the source dataset.

Rooftop footage captured by the author is original work, licensed
`CC-BY-NC-ND-4.0` under `docs/` or `data/` as applicable, and subject to the
sanitization requirements in the repository's contribution rules — no
coordinates, no site-identifying detail, no hostnames.

---

## Maintenance

Update this file in the same commit that adds, removes, or upgrades a
dependency. An entry requires: component, license identifier, upstream URL,
and consuming tree. If a license cannot be determined, do not add the
dependency.
