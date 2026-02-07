import asyncio
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional, Tuple

from app.core.errors import ProcessingFailedError, TimeoutError
from app.core.storage import ensure_directory, remove_file
from app.pipelines.base import ProgressUpdate


# Progress stage weights (must sum to 100)
SFM_WEIGHT = 40.0  # Structure from Motion
TRAINING_WEIGHT = 55.0  # Gaussian Splatting training
EXPORT_WEIGHT = 5.0  # Model export

# Stage timeout constants (in seconds)
SFM_TIMEOUT_SECONDS = 1800  # 30 minutes for SfM
TRAINING_TIMEOUT_SECONDS = 3600  # 60 minutes for training
EXPORT_TIMEOUT_SECONDS = 300  # 5 minutes for export

# Regex patterns for parsing nerfstudio output
# SfM phase patterns
RE_SFM_EXTRACT = re.compile(r"Feature extraction:\s*(\d+)/(\d+)", re.IGNORECASE)
RE_SFM_MATCH = re.compile(r"Feature matching:\s*(\d+)/(\d+)", re.IGNORECASE)
RE_SFM_RECONSTRUCT = re.compile(r"(?:registered|Registering image)\s+(?:#)?(\d+)\s*(?:\((\d+)\)|of\s+(\d+))?", re.IGNORECASE)
# Training phase pattern — matches "Step 1000/30000" anywhere in line
RE_TRAIN_STEP = re.compile(r"Step\s+(\d+)/(\d+)", re.IGNORECASE)
# COLMAP image registration (alternative format)
RE_COLMAP_IMAGES = re.compile(r"Registering image #(\d+)\s+\((\d+)\)", re.IGNORECASE)


class NerfstudioPipeline:
    """Nerfstudio pipeline for processing video to 3DGS with real-time progress."""

    ARTIFACT_FORMAT = "ply"

    async def process(
        self,
        input_path: Path,
        output_path: Path,
        job_id: str,
        on_progress: Optional[Callable[[ProgressUpdate], None]] = None,
    ) -> Tuple[str, str]:
        """Process input video through nerfstudio pipeline with progress reporting."""

        if not shutil.which("ns-process-data"):
            raise ProcessingFailedError(
                "nerfstudio not available: 'ns-process-data' command not found"
            )

        work_dir = output_path.parent / f"ns_work_{job_id}"
        ensure_directory(work_dir)

        def report(percent: Optional[float], stage: str, msg: str) -> None:
            """Report progress update with monotonicity guarantee."""
            if on_progress is not None:
                clamped_percent = None
                if percent is not None:
                    clamped_percent = max(0.0, min(100.0, percent))
                update = ProgressUpdate(
                    percent=clamped_percent,
                    stage=stage,
                    message=msg[:512],  # Enforce max length
                    ts=datetime.now(timezone.utc),
                )
                on_progress(update)

        last_stage = None
        last_percent = None

        def report_monotonic(percent: Optional[float], stage: str, msg: str) -> None:
            """Report progress with monotonicity enforcement."""
            nonlocal last_stage, last_percent

            # Stage progression: sfm -> train -> export (never go backwards)
            stage_order = {"sfm": 0, "train": 1, "export": 2}
            current_stage_order = stage_order.get(stage, -1)

            if last_stage is not None:
                last_stage_order = stage_order.get(last_stage, -1)
                if current_stage_order < last_stage_order:
                    # Stage regression: ignore
                    return
                elif current_stage_order == last_stage_order:
                    # Same stage: check percent monotonicity
                    if percent is not None and last_percent is not None:
                        if percent < last_percent:
                            # Percent regression: ignore
                            return

            # Update and report
            last_stage = stage
            if percent is not None:
                last_percent = percent
            report(percent, stage, msg)

        try:
            # Phase 1: SfM (0% → 40%)
            report_monotonic(0.0, "sfm", "Starting structure from motion...")
            await self._run_sfm(input_path, work_dir, report_monotonic)

            # Phase 2: Training (40% → 95%)
            report_monotonic(SFM_WEIGHT, "train", "Starting Gaussian Splatting training...")
            await self._run_training(work_dir, report_monotonic)

            # Phase 3: Export (95% → 100%)
            report_monotonic(SFM_WEIGHT + TRAINING_WEIGHT, "export", "Exporting model...")
            ply_file = self._find_output_ply(work_dir)
            if not ply_file:
                raise ProcessingFailedError("nerfstudio did not produce output PLY file")

            artifact_filename = f"{job_id}.ply"
            artifact_path = output_path.parent / artifact_filename
            shutil.copy2(ply_file, artifact_path)

            report_monotonic(100.0, "export", "Complete")
            return str(artifact_path), self.ARTIFACT_FORMAT

        finally:
            remove_file(work_dir)

    async def _run_sfm(
        self,
        input_path: Path,
        work_dir: Path,
        report: Callable[[Optional[float], str, str], None],
    ) -> None:
        """Run SfM phase with progress parsing."""
        cmd = [
            "ns-process-data",
            "video",
            str(input_path),
            "--output-dir",
            str(work_dir),
        ]

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        # SfM sub-stages: extract (0-15%), match (15-30%), reconstruct (30-40%)
        sfm_sub_weights = {
            "extract": (0.0, 15.0),
            "match": (15.0, 30.0),
            "reconstruct": (30.0, 40.0),
        }

        last_progress_time = asyncio.get_event_loop().time()
        current_stage = "extract"
        current_percent = 0.0

        async def _parse_sfm_output(stream: asyncio.StreamReader) -> None:
            """Parse SfM output stream for progress indicators."""
            nonlocal last_progress_time, current_stage, current_percent
            buffer = b""
            while True:
                try:
                    chunk = await asyncio.wait_for(stream.read(4096), timeout=1.0)
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line_bytes, buffer = buffer.split(b"\n", 1)
                        line = line_bytes.decode("utf-8", errors="replace")

                        # Try each pattern
                        m = RE_SFM_EXTRACT.search(line)
                        if m:
                            current, total = int(m.group(1)), int(m.group(2))
                            if total > 0:
                                sub_pct = current / total
                                start, end = sfm_sub_weights["extract"]
                                pct = start + sub_pct * (end - start)
                                current_percent = pct
                                current_stage = "extract"
                                last_progress_time = asyncio.get_event_loop().time()
                                report(pct, "sfm", f"Extracting features: {current}/{total} images")
                            continue

                        m = RE_SFM_MATCH.search(line)
                        if m:
                            current, total = int(m.group(1)), int(m.group(2))
                            if total > 0:
                                sub_pct = current / total
                                start, end = sfm_sub_weights["match"]
                                pct = start + sub_pct * (end - start)
                                current_percent = pct
                                current_stage = "match"
                                last_progress_time = asyncio.get_event_loop().time()
                                report(pct, "sfm", f"Matching features: {current}/{total} pairs")
                            continue

                        m = RE_SFM_RECONSTRUCT.search(line)
                        if m:
                            current = int(m.group(1))
                            total = int(m.group(2)) if m.group(2) else (int(m.group(3)) if m.group(3) else None)
                            if total and total > 0:
                                sub_pct = current / total
                                start, end = sfm_sub_weights["reconstruct"]
                                pct = start + sub_pct * (end - start)
                                current_percent = pct
                                current_stage = "reconstruct"
                                last_progress_time = asyncio.get_event_loop().time()
                                report(pct, "sfm", f"Reconstructing: {current}/{total} images registered")
                            else:
                                # Progress without total: just update message
                                last_progress_time = asyncio.get_event_loop().time()
                                report(current_percent, "sfm", f"Registering image {current}")
                            continue

                except asyncio.TimeoutError:
                    # Check for stage timeout
                    elapsed = asyncio.get_event_loop().time() - last_progress_time
                    if elapsed > SFM_TIMEOUT_SECONDS:
                        raise TimeoutError(
                            f"SfM phase timed out after {SFM_TIMEOUT_SECONDS}s "
                            f"(last progress: {current_percent:.1f}% in {current_stage})"
                        )
                    continue
                except Exception:
                    # Ignore parsing errors, continue reading
                    continue

        try:
            # Read both stdout and stderr concurrently
            parse_task = asyncio.create_task(_parse_sfm_output(process.stderr))
            # Also drain stdout to prevent pipe blocking
            stdout_task = asyncio.create_task(process.stdout.read())

            # Wait for process completion or timeout
            done, pending = await asyncio.wait(
                [parse_task, stdout_task, asyncio.create_task(process.wait())],
                timeout=SFM_TIMEOUT_SECONDS + 10,  # Extra buffer for cleanup
                return_when=asyncio.FIRST_COMPLETED,
            )

            # Check if process completed
            if process.returncode is None:
                # Process still running: check for timeout
                elapsed = asyncio.get_event_loop().time() - last_progress_time
                if elapsed > SFM_TIMEOUT_SECONDS:
                    process.kill()
                    await process.wait()
                    raise TimeoutError(
                        f"SfM phase timed out after {SFM_TIMEOUT_SECONDS}s "
                        f"(last progress: {current_percent:.1f}% in {current_stage})"
                    )

            # Wait for process to finish
            await process.wait()

            # Cancel pending tasks
            for task in pending:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

            # Wait for parsing to finish (with timeout)
            try:
                await asyncio.wait_for(parse_task, timeout=5.0)
            except asyncio.TimeoutError:
                parse_task.cancel()
                try:
                    await parse_task
                except asyncio.CancelledError:
                    pass

        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise TimeoutError(
                f"SfM phase timed out after {SFM_TIMEOUT_SECONDS}s "
                f"(last progress: {current_percent:.1f}% in {current_stage})"
            )

        if process.returncode != 0:
            stderr_data = b""
            if process.stderr:
                try:
                    stderr_data = await process.stderr.read()
                except Exception:
                    pass
            error_msg = stderr_data.decode("utf-8", errors="ignore") if stderr_data else "Unknown error"
            raise ProcessingFailedError(
                f"SfM failed with return code {process.returncode}: {error_msg}"
            )

    async def _run_training(
        self,
        work_dir: Path,
        report: Callable[[Optional[float], str, str], None],
    ) -> None:
        """Run Gaussian Splatting training with progress parsing."""
        cmd = [
            "ns-train",
            "splatfacto",
            "--data",
            str(work_dir),
            "--output-dir",
            str(work_dir / "outputs"),
            "--max-num-iterations",
            "30000",
            "--viewer.quit-on-train-completion",
            "True",
        ]

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        last_progress_time = asyncio.get_event_loop().time()
        current_percent = SFM_WEIGHT

        async def _parse_training_output(stream: asyncio.StreamReader) -> None:
            """Parse training output for step progress."""
            nonlocal last_progress_time, current_percent
            buffer = b""
            while True:
                try:
                    chunk = await asyncio.wait_for(stream.read(4096), timeout=1.0)
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line_bytes, buffer = buffer.split(b"\n", 1)
                        line = line_bytes.decode("utf-8", errors="replace")

                        m = RE_TRAIN_STEP.search(line)
                        if m:
                            current, total = int(m.group(1)), int(m.group(2))
                            if total > 0:
                                train_pct = current / total
                                pct = SFM_WEIGHT + train_pct * TRAINING_WEIGHT
                                current_percent = pct
                                last_progress_time = asyncio.get_event_loop().time()
                                report(pct, "train", f"Training: step {current}/{total}")

                except asyncio.TimeoutError:
                    # Check for stage timeout
                    elapsed = asyncio.get_event_loop().time() - last_progress_time
                    if elapsed > TRAINING_TIMEOUT_SECONDS:
                        raise TimeoutError(
                            f"Training phase timed out after {TRAINING_TIMEOUT_SECONDS}s "
                            f"(last progress: {current_percent:.1f}%)"
                        )
                    continue
                except Exception:
                    # Ignore parsing errors, continue reading
                    continue

        try:
            parse_task = asyncio.create_task(_parse_training_output(process.stderr))
            stdout_task = asyncio.create_task(process.stdout.read())

            done, pending = await asyncio.wait(
                [parse_task, stdout_task, asyncio.create_task(process.wait())],
                timeout=TRAINING_TIMEOUT_SECONDS + 10,
                return_when=asyncio.FIRST_COMPLETED,
            )

            if process.returncode is None:
                elapsed = asyncio.get_event_loop().time() - last_progress_time
                if elapsed > TRAINING_TIMEOUT_SECONDS:
                    process.kill()
                    await process.wait()
                    raise TimeoutError(
                        f"Training phase timed out after {TRAINING_TIMEOUT_SECONDS}s "
                        f"(last progress: {current_percent:.1f}%)"
                    )

            await process.wait()

            for task in pending:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

            try:
                await asyncio.wait_for(parse_task, timeout=5.0)
            except asyncio.TimeoutError:
                parse_task.cancel()
                try:
                    await parse_task
                except asyncio.CancelledError:
                    pass

        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise TimeoutError(
                f"Training phase timed out after {TRAINING_TIMEOUT_SECONDS}s "
                f"(last progress: {current_percent:.1f}%)"
            )

        if process.returncode != 0:
            stderr_data = b""
            if process.stderr:
                try:
                    stderr_data = await process.stderr.read()
                except Exception:
                    pass
            error_msg = stderr_data.decode("utf-8", errors="ignore") if stderr_data else "Unknown error"
            raise ProcessingFailedError(
                f"Training failed with return code {process.returncode}: {error_msg}"
            )

    def _find_output_ply(self, work_dir: Path) -> Optional[Path]:
        """Find output PLY file in work directory."""
        for pattern in ["*.ply", "**/*.ply"]:
            for ply_file in work_dir.glob(pattern):
                if ply_file.is_file():
                    return ply_file
        return None
