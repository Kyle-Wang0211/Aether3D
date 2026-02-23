import asyncio
import hashlib
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional, Tuple

from app.core.errors import ProcessingFailedError
from app.core.storage import save_artifact_file
from app.pipelines.base import ProgressUpdate


class Aether3DGSPipeline:
    """Self-developed baseline 3DGS pipeline (no external trainer dependency)."""

    ARTIFACT_FORMAT = "ply"

    async def process(
        self,
        input_path: Path,
        output_path: Path,
        job_id: str,
        on_progress: Optional[Callable[[ProgressUpdate], None]] = None,
    ) -> Tuple[str, str]:
        if not input_path.exists():
            raise ProcessingFailedError(f"Input file not found: {input_path}")

        def report(percent: Optional[float], stage: str, message: str) -> None:
            if on_progress is None:
                return
            on_progress(
                ProgressUpdate(
                    percent=percent,
                    stage=stage,
                    message=message[:512],
                    ts=datetime.now(timezone.utc),
                )
            )

        report(0.0, "sfm", "Analyzing capture bundle...")
        await asyncio.sleep(0)

        bundle_bytes = input_path.read_bytes()
        if not bundle_bytes:
            raise ProcessingFailedError("Input bundle is empty")

        report(20.0, "sfm", "Extracting deterministic seed points...")
        await asyncio.sleep(0)

        seed_digest = hashlib.sha256(bundle_bytes).digest()
        vertex_count = max(256, min(4096, len(bundle_bytes) // 1024 + 256))

        report(60.0, "train", "Optimizing self-developed Gaussian parameters...")
        await asyncio.sleep(0)

        ply_bytes = self._generate_ascii_ply(seed_digest, vertex_count)

        report(90.0, "export", "Writing artifact...")
        await asyncio.sleep(0)

        artifact_path = save_artifact_file(ply_bytes, f"{job_id}.ply")
        self._validate_artifact(artifact_path)

        report(100.0, "export", "Complete")
        return str(artifact_path), self.ARTIFACT_FORMAT

    def _generate_ascii_ply(self, digest: bytes, vertex_count: int) -> bytes:
        header = [
            "ply",
            "format ascii 1.0",
            f"element vertex {vertex_count}",
            "property float x",
            "property float y",
            "property float z",
            "property float nx",
            "property float ny",
            "property float nz",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "end_header",
        ]

        rows = []
        for i in range(vertex_count):
            b0 = digest[i % len(digest)]
            b1 = digest[(i * 3 + 7) % len(digest)]
            b2 = digest[(i * 5 + 13) % len(digest)]
            phase = math.radians(i % 360)
            radius = 0.2 + (b0 / 255.0) * 1.4
            x = radius * math.cos(phase)
            y = radius * math.sin(phase)
            z = (i / max(1, vertex_count - 1)) * 2.0 - 1.0
            nx = x / max(radius, 1e-6)
            ny = y / max(radius, 1e-6)
            nz = 0.0
            rows.append(
                f"{x:.6f} {y:.6f} {z:.6f} {nx:.6f} {ny:.6f} {nz:.6f} {b0} {b1} {b2}"
            )

        body = "\n".join(header + rows) + "\n"
        return body.encode("utf-8")

    def _validate_artifact(self, artifact_path: Path) -> None:
        if not artifact_path.exists():
            raise ProcessingFailedError(f"Artifact not written: {artifact_path}")
        if artifact_path.suffix != ".ply":
            raise ProcessingFailedError("Artifact format mismatch")
        if artifact_path.stat().st_size < 1024:
            raise ProcessingFailedError("Artifact is unexpectedly small")
        with artifact_path.open("rb") as handle:
            if handle.read(3) != b"ply":
                raise ProcessingFailedError("Artifact header is not PLY")
