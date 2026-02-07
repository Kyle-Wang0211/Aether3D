# PR: Replace 180s Hard Timeout with Real Progress Reporting + Stall Detection

## Constitutional Prompt · Production Pipeline · Cross-Platform · Industrial Hardened

**Version**: PR-PROGRESS-1.0
**Stage**: POST-WHITEBOX → PRODUCTION
**Scope**: Server pipeline progress reporting + Client stall-based timeout
**Prerequisites**: PR#1, PR#2, PR#3, PR#5
**Motivation**: The current 180-second hard timeout in `PipelineRunner.swift` makes it impossible to process videos longer than ~30 seconds. Users can record up to 15 minutes (`CaptureRecordingConstants.maxDurationSeconds = 900`), but the pipeline kills the job after 3 minutes regardless of actual progress. This PR replaces the fixed timeout with real server-side progress reporting and client-side stall detection.

---

## §0 PROBLEM STATEMENT

### §0.1 The Contradiction (Quantified)

| Constraint | Value | Source |
|-----------|-------|--------|
| Max recording duration | 900s (15 min) | `CaptureRecordingConstants.maxDurationSeconds` |
| Max frame count | 1800 frames (15min × 2fps) | `SamplingConstants.maxFrameCount` |
| Pipeline hard timeout | 180s (3 min) | `PipelineRunner.swift:88`, `PipelineRunner.swift:245` |
| Server pipeline timeout | 180s (3 min) | `nerfstudio.py:15` `TIMEOUT_SECONDS = 180` |

A 15-minute video at 1080p ≈ 1.08GB. Upload alone at 10 Mbps takes ~14 minutes. Nerfstudio training for 30,000 steps on a single GPU takes 15-45 minutes depending on scene complexity. The 180s timeout guarantees failure for any real-world input.

### §0.2 Current Server Progress is Fake

`server/app/api/handlers/job_handlers.py:130-135` returns hardcoded percentages:
```python
if job.state == "queued":
    progress = JobProgress(stage="queued", percentage=0, message="Waiting in queue")
elif job.state == "processing":
    progress = JobProgress(stage="sfm", percentage=50, message="Running structure from motion")
elif job.state == "packaging":
    progress = JobProgress(stage="packaging", percentage=90, message="Packaging output")
```

The client `ProgressEstimator` (which uses EMA-based estimation and psychological optimization) receives this static `50%` for the entire processing duration. The stall detection system (`RetryConstants.stallDetectionSeconds = 300`) would false-trigger because progress never changes.

### §0.3 What Already Works (Do NOT Rebuild)

| Component | Location | Status |
|-----------|----------|--------|
| `ProgressEstimator` with EMA | `Core/Jobs/ProgressEstimator.swift` | ✅ Ready — needs real data |
| `calculatePerceivedProgress()` | `Core/Jobs/ProgressEstimator.swift:101` | ✅ Ready — psychological optimization |
| `shouldReportProgress()` | `Core/Jobs/ProgressEstimator.swift:128` | ✅ Ready — 2% minimum increment |
| `UploadProgressTracker` pattern | `Core/Upload/UploadProgressTracker.swift` | ✅ Ready — follow this pattern |
| `JobStatus` enum with progress | `Core/Pipeline/RemoteB1Client.swift:28` | ✅ Has `progress: Double?` |
| `UIState.generating(progress:)` | `App/Demo/PipelineDemoViewModel.swift:18` | ✅ Ready — UI binding exists |
| Stall detection constant | `RetryConstants.stallDetectionSeconds = 300` | ✅ Ready — 5min threshold |
| Heartbeat constant | `RetryConstants.heartbeatIntervalSeconds = 30` | ✅ Ready |
| `FailureReason.stalledProcessing` | `Core/Jobs/FailureReason.swift:24` | ✅ Already defined |
| `FailureReason.heartbeatTimeout` | `Core/Jobs/FailureReason.swift:23` | ✅ Already defined |
| Pipeline Protocol | `server/app/pipelines/base.py` | ✅ Has `process()` signature |
| Dummy pipeline | `server/app/pipelines/dummy.py` | ✅ Test pipeline exists |
| Job model with progress field | `server/app/models.py:158` | ✅ Has `progress: Optional[float]` in `JobStatusResponse` |

---

## §1 CHANGES REQUIRED — OVERVIEW

### Change 1: Server-Side Real Progress Reporting (Python)
Parse nerfstudio subprocess stdout in real-time. Write progress to database. Expose via existing `GET /v1/jobs/{id}` endpoint.

### Change 2: Client-Side Stall-Based Timeout (Swift)
Remove `Timeout.withTimeout(seconds: 180)`. Replace with progress-aware polling loop that detects stalls (no progress change for N seconds).

### Change 3: Constants & Contract Updates
Add new constants for progress-based timeout. Update WHITEBOX.md and ACCEPTANCE.md to reflect new behavior. Register all new constants in SSOT.

### Change 4: Cross-Platform Guardrails
iOS background task handling. Linux CI compatibility. Audit trail for timeout decisions.

---

## §2 CHANGE 1 — SERVER-SIDE REAL PROGRESS (Python)

### §2.1 Nerfstudio Output Format

Nerfstudio (`ns-train splatfacto`) writes progress to stderr in this format:
```
Printing max of 10 lines from the eval tables...
╭──────────────────────────────────── ─────────────────────────────────────╮
│                         Trainer Summary                                  │
│ ──────────────────────────────────────────────────────────────────────── │
│ Steps   : 30000                                                          │
│ Max Steps: 30000                                                         │
╰──────────────────────────────────────────────────────────────────────────╯
Step 100/30000 | Loss: 0.1234 | PSNR: 18.32 | Time: 0.12s
Step 200/30000 | Loss: 0.0987 | PSNR: 20.45 | Time: 0.11s
...
```

The key progress line pattern is: `Step {current}/{total}`

For `ns-process-data video`, the output includes COLMAP SfM progress:
```
[SfM] Feature extraction: 50/200 images
[SfM] Feature matching: 1000/5000 pairs
[SfM] Sparse reconstruction: 150/200 registered images
```

### §2.2 Pipeline Protocol Extension

**File**: `server/app/pipelines/base.py`

Extend the `Pipeline` protocol to support a progress callback:

```python
from pathlib import Path
from typing import Callable, Optional, Protocol, Tuple


class ProgressCallback(Protocol):
    """Callback for reporting pipeline progress."""
    def __call__(self, percentage: float, stage: str, message: str) -> None: ...


class Pipeline(Protocol):
    """Pipeline protocol for processing video to 3D artifact."""

    async def process(
        self,
        input_path: Path,
        output_path: Path,
        job_id: str,
        on_progress: Optional[Callable[[float, str, str], None]] = None,
    ) -> Tuple[str, str]:
        """
        Process input video and generate artifact.

        Args:
            input_path: Path to input video file
            output_path: Path where artifact should be saved
            job_id: Job ID for naming output file
            on_progress: Optional callback(percentage, stage, message)
                         percentage: 0.0-100.0
                         stage: "sfm_extract" | "sfm_match" | "sfm_reconstruct" | "gs_train" | "export"
                         message: Human-readable status message

        Returns:
            Tuple of (artifact_path, artifact_format)
        """
        ...
```

**IMPORTANT**: The existing `process(input_path, output_path, job_id)` signature in `DummyPipeline` and `NerfstudioPipeline` must remain backward-compatible. Add `on_progress=None` as an optional parameter with default `None`. Callers that don't pass it continue to work.

### §2.3 Nerfstudio Pipeline — Real Progress Parsing

**File**: `server/app/pipelines/nerfstudio.py`

Replace the current "fire and wait" implementation with real-time stdout/stderr parsing.

**Architecture**: The nerfstudio pipeline has TWO phases:
1. **SfM phase** (`ns-process-data video`): Structure from Motion — extracts features, matches, reconstructs sparse point cloud. Weight: 40% of total progress.
2. **Training phase** (`ns-train splatfacto`): 3D Gaussian Splatting training — iterates N steps. Weight: 55% of total progress.
3. **Export phase**: Convert trained model to .ply. Weight: 5% of total progress.

```python
import asyncio
import re
import shutil
from pathlib import Path
from typing import Callable, Optional, Tuple

from app.core.errors import ProcessingFailedError, TimeoutError
from app.core.storage import ensure_directory, remove_file


# Progress stage weights (must sum to 100)
SFM_WEIGHT = 40.0        # Structure from Motion
TRAINING_WEIGHT = 55.0    # Gaussian Splatting training
EXPORT_WEIGHT = 5.0       # Model export

# Regex patterns for parsing nerfstudio output
# SfM phase patterns
RE_SFM_EXTRACT = re.compile(r"Feature extraction:\s*(\d+)/(\d+)")
RE_SFM_MATCH = re.compile(r"Feature matching:\s*(\d+)/(\d+)")
RE_SFM_RECONSTRUCT = re.compile(r"(?:registered|Registered)\s+(\d+)/(\d+)")
# Training phase pattern — matches "Step 1000/30000" anywhere in line
RE_TRAIN_STEP = re.compile(r"Step\s+(\d+)/(\d+)")
# COLMAP image registration (alternative format)
RE_COLMAP_IMAGES = re.compile(r"Registering image #(\d+)\s+\((\d+)\)")


class NerfstudioPipeline:
    """Nerfstudio pipeline for processing video to 3DGS with real-time progress."""

    ARTIFACT_FORMAT = "ply"
    # No hard timeout — stall detection is handled by the caller/client
    # Server-side per-phase timeouts prevent individual subprocess hangs
    SFM_TIMEOUT_SECONDS = 1800      # 30 minutes for SfM (scales with video length)
    TRAINING_TIMEOUT_SECONDS = 3600  # 60 minutes for training
    EXPORT_TIMEOUT_SECONDS = 300     # 5 minutes for export

    async def process(
        self,
        input_path: Path,
        output_path: Path,
        job_id: str,
        on_progress: Optional[Callable[[float, str, str], None]] = None,
    ) -> Tuple[str, str]:
        """Process input video through nerfstudio pipeline with progress reporting."""

        if not shutil.which("ns-process-data"):
            raise ProcessingFailedError(
                "nerfstudio not available: 'ns-process-data' command not found"
            )

        work_dir = output_path.parent / f"ns_work_{job_id}"
        ensure_directory(work_dir)

        def report(pct: float, stage: str, msg: str) -> None:
            if on_progress is not None:
                # Clamp to [0, 100]
                clamped = max(0.0, min(100.0, pct))
                on_progress(clamped, stage, msg)

        try:
            # Phase 1: SfM (0% → 40%)
            report(0.0, "sfm_extract", "Starting structure from motion...")
            await self._run_sfm(input_path, work_dir, report)

            # Phase 2: Training (40% → 95%)
            report(SFM_WEIGHT, "gs_train", "Starting Gaussian Splatting training...")
            await self._run_training(work_dir, report)

            # Phase 3: Export (95% → 100%)
            report(SFM_WEIGHT + TRAINING_WEIGHT, "export", "Exporting model...")
            ply_file = self._find_output_ply(work_dir)
            if not ply_file:
                raise ProcessingFailedError("nerfstudio did not produce output PLY file")

            artifact_filename = f"{job_id}.ply"
            artifact_path = output_path.parent / artifact_filename
            shutil.copy2(ply_file, artifact_path)

            report(100.0, "export", "Complete")
            return str(artifact_path), self.ARTIFACT_FORMAT

        finally:
            remove_file(work_dir)

    async def _run_sfm(
        self,
        input_path: Path,
        work_dir: Path,
        report: Callable[[float, str, str], None],
    ) -> None:
        """Run SfM phase with progress parsing."""
        cmd = [
            "ns-process-data", "video",
            str(input_path),
            "--output-dir", str(work_dir),
        ]

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        # Parse stderr line-by-line for progress
        # SfM sub-stages: extract (0-15%), match (15-30%), reconstruct (30-40%)
        sfm_sub_weights = {
            "extract": (0.0, 15.0),
            "match": (15.0, 30.0),
            "reconstruct": (30.0, 40.0),
        }

        async def _parse_sfm_output(stream: asyncio.StreamReader) -> None:
            """Parse SfM output stream for progress indicators."""
            buffer = b""
            while True:
                chunk = await stream.read(4096)
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
                            report(pct, "sfm_extract", f"Extracting features: {current}/{total} images")
                        continue

                    m = RE_SFM_MATCH.search(line)
                    if m:
                        current, total = int(m.group(1)), int(m.group(2))
                        if total > 0:
                            sub_pct = current / total
                            start, end = sfm_sub_weights["match"]
                            pct = start + sub_pct * (end - start)
                            report(pct, "sfm_match", f"Matching features: {current}/{total} pairs")
                        continue

                    m = RE_SFM_RECONSTRUCT.search(line)
                    if m:
                        current, total = int(m.group(1)), int(m.group(2))
                        if total > 0:
                            sub_pct = current / total
                            start, end = sfm_sub_weights["reconstruct"]
                            pct = start + sub_pct * (end - start)
                            report(pct, "sfm_reconstruct", f"Reconstructing: {current}/{total} images registered")
                        continue

        try:
            # Read both stdout and stderr concurrently
            parse_task = asyncio.create_task(_parse_sfm_output(process.stderr))
            # Also drain stdout to prevent pipe blocking
            stdout_data = await asyncio.wait_for(
                process.stdout.read(),
                timeout=self.SFM_TIMEOUT_SECONDS,
            )
            await asyncio.wait_for(parse_task, timeout=10)  # parsing should finish quickly after process
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise TimeoutError(f"SfM phase timed out after {self.SFM_TIMEOUT_SECONDS}s")

        await process.wait()
        if process.returncode != 0:
            raise ProcessingFailedError(f"SfM failed with return code {process.returncode}")

    async def _run_training(
        self,
        work_dir: Path,
        report: Callable[[float, str, str], None],
    ) -> None:
        """Run Gaussian Splatting training with progress parsing."""
        cmd = [
            "ns-train", "splatfacto",
            "--data", str(work_dir),
            "--output-dir", str(work_dir / "outputs"),
            "--max-num-iterations", "30000",
            "--viewer.quit-on-train-completion", "True",
        ]

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        async def _parse_training_output(stream: asyncio.StreamReader) -> None:
            """Parse training output for step progress."""
            buffer = b""
            while True:
                chunk = await stream.read(4096)
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
                            report(pct, "gs_train", f"Training: step {current}/{total}")

        try:
            parse_task = asyncio.create_task(_parse_training_output(process.stderr))
            stdout_data = await asyncio.wait_for(
                process.stdout.read(),
                timeout=self.TRAINING_TIMEOUT_SECONDS,
            )
            await asyncio.wait_for(parse_task, timeout=10)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise TimeoutError(f"Training phase timed out after {self.TRAINING_TIMEOUT_SECONDS}s")

        await process.wait()
        if process.returncode != 0:
            raise ProcessingFailedError(f"Training failed with return code {process.returncode}")

    def _find_output_ply(self, work_dir: Path) -> Optional[Path]:
        """Find output PLY file in work directory."""
        for pattern in ["*.ply", "**/*.ply"]:
            for ply_file in work_dir.glob(pattern):
                if ply_file.is_file():
                    return ply_file
        return None
```

### §2.4 Job Service — Write Progress to Database

**File**: `server/app/services/job_service.py`

Update `process_job` to pass a progress callback that writes to the database.

```python
import asyncio
from pathlib import Path

from app.core.errors import NotFoundError, ProcessingFailedError
from app.core.storage import get_artifact_file_path
from app.pipelines.factory import create_pipeline
from app.repositories.asset_repo import AssetRepository
from app.repositories.job_repo import JobRepository


class JobService:
    def __init__(self, job_repo: JobRepository, asset_repo: AssetRepository):
        self.job_repo = job_repo
        self.asset_repo = asset_repo

    async def process_job(self, job_id: str, pipeline_type: str = "dummy") -> None:
        """Process job asynchronously with real-time progress updates."""
        job = self.job_repo.get_by_id(job_id)
        if not job:
            raise NotFoundError("Job", job_id)

        asset = self.asset_repo.get_by_id(job.asset_id)
        if not asset:
            raise NotFoundError("Asset", job.asset_id)

        # Update status to processing
        job.status = "processing"
        job.progress = "0.0"
        self.job_repo.update(job)

        # Throttle DB writes to avoid excessive I/O
        _last_written_pct = [-1.0]  # mutable container for closure
        MIN_DB_WRITE_INCREMENT = 1.0  # Don't write to DB for <1% changes

        def on_progress(percentage: float, stage: str, message: str) -> None:
            """Write progress to database (throttled)."""
            if abs(percentage - _last_written_pct[0]) >= MIN_DB_WRITE_INCREMENT:
                _last_written_pct[0] = percentage
                job.progress = str(round(percentage, 1))
                job.progress_stage = stage
                job.progress_message = message
                self.job_repo.update(job)

        try:
            pipeline = create_pipeline(pipeline_type)

            input_path = Path(asset.file_path)
            output_dir = Path(asset.file_path).parent.parent / "artifacts"
            artifact_path, artifact_format = await pipeline.process(
                input_path, output_dir, job_id,
                on_progress=on_progress,
            )

            job.artifact_path = artifact_path
            job.artifact_format = artifact_format
            job.status = "completed"
            job.progress = "100.0"
            self.job_repo.update(job)

        except Exception as e:
            error_msg = str(e)
            if isinstance(e, ProcessingFailedError):
                error_msg = e.message
            job.status = "failed"
            job.error_message = error_msg
            self.job_repo.update(job)
            raise
```

### §2.5 Job Model — Add Progress Fields

**File**: `server/app/models.py`

Add `progress_stage` and `progress_message` columns to the `Job` model:

```python
class Job(Base):
    """任务模型（扩展）"""
    __tablename__ = "jobs"

    id = Column(String, primary_key=True)
    user_id = Column(String, nullable=False, index=True)
    bundle_hash = Column(String, nullable=False, index=True)
    state = Column(String, nullable=False, default="queued")
    progress = Column(String, nullable=True)          # "0.0" to "100.0"
    progress_stage = Column(String, nullable=True)     # NEW: "sfm_extract" | "sfm_match" | ... | "gs_train" | "export"
    progress_message = Column(String, nullable=True)   # NEW: Human-readable message
    failure_reason = Column(String, nullable=True)
    cancel_reason = Column(String, nullable=True)
    processing_started_at = Column(DateTime(timezone=True), nullable=True)
    artifact_id = Column(String, nullable=True, index=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    # ... (relationships unchanged)
```

### §2.6 Job Handler — Return Real Progress

**File**: `server/app/api/handlers/job_handlers.py`

Replace the hardcoded progress with database-sourced values:

```python
# REPLACE this block (lines 129-135):
#     if job.state == "queued":
#         progress = JobProgress(stage="queued", percentage=0, message="Waiting in queue")
#     elif job.state == "processing":
#         progress = JobProgress(stage="sfm", percentage=50, message="Running structure from motion")
#     elif job.state == "packaging":
#         progress = JobProgress(stage="packaging", percentage=90, message="Packaging output")

# WITH:
progress: Optional[JobProgress] = None
if job.state == "queued":
    progress = JobProgress(stage="queued", percentage=0, message="Waiting in queue")
elif job.state == "processing":
    # Use real progress from database (written by pipeline)
    pct = 0
    stage = "processing"
    message = "Processing..."
    if job.progress:
        try:
            pct = int(float(job.progress))
        except (ValueError, TypeError):
            pass
    if job.progress_stage:
        stage = job.progress_stage
    if job.progress_message:
        message = job.progress_message
    progress = JobProgress(stage=stage, percentage=pct, message=message)
elif job.state == "packaging":
    progress = JobProgress(stage="packaging", percentage=95, message="Packaging output")
elif job.state == "completed":
    progress = JobProgress(stage="complete", percentage=100, message="Done")
```

### §2.7 Dummy Pipeline — Add Progress Simulation

**File**: `server/app/pipelines/dummy.py`

Update the dummy pipeline to simulate progress (for testing):

```python
async def process(
    self,
    input_path: Path,
    output_path: Path,
    job_id: str,
    on_progress: Optional[Callable[[float, str, str], None]] = None,
) -> Tuple[str, str]:
    """Process with simulated progress."""

    # Simulate SfM (0% → 40%)
    for i in range(5):
        await asyncio.sleep(0.2)
        if on_progress:
            pct = (i + 1) / 5 * 40.0
            on_progress(pct, "sfm_extract", f"Simulated SfM: {(i+1)*20}%")

    # Simulate training (40% → 95%)
    for i in range(10):
        await asyncio.sleep(0.1)
        if on_progress:
            pct = 40.0 + (i + 1) / 10 * 55.0
            on_progress(pct, "gs_train", f"Simulated training: step {(i+1)*3000}/30000")

    # Simulate export (95% → 100%)
    if on_progress:
        on_progress(100.0, "export", "Complete")

    ply_content = self._generate_ply_content(vertex_count=300)
    filename = f"{job_id}.ply"
    artifact_path = save_artifact_file(ply_content, filename)
    self._validate_artifact(artifact_path, self.ARTIFACT_FORMAT)
    return str(artifact_path), self.ARTIFACT_FORMAT
```

---

## §3 CHANGE 2 — CLIENT-SIDE STALL-BASED TIMEOUT (Swift)

### §3.1 New Constants

**File**: `Core/Constants/PipelineTimeoutConstants.swift` (NEW FILE)

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR-PROGRESS-1.0
// Module: Pipeline Timeout Constants (SSOT)
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Pipeline timeout constants — replaces the old 180s hard timeout
/// with stall-based detection that allows long-running jobs to complete
/// as long as progress is being made.
///
/// ## Design Rationale
/// - A 15-minute video (900s) can take 15-45 minutes to process
/// - Hard timeouts cause false failures on legitimate long jobs
/// - Stall detection catches genuinely stuck jobs without penalizing slow ones
/// - Industry reference: Replicate.com uses stall-based timeouts for ML training
///
/// ## Safety Layers (Defense in Depth)
/// 1. Per-poll stall detection: no progress change for `stallTimeoutSeconds`
/// 2. Absolute maximum: `absoluteMaxTimeoutSeconds` prevents infinite hangs
/// 3. Server-side per-phase timeouts: SfM (30min), Training (60min), Export (5min)
/// 4. iOS background task watchdog: system-enforced limits
public enum PipelineTimeoutConstants {

    // =========================================================================
    // MARK: - Stall Detection
    // =========================================================================

    /// Stall detection timeout in seconds.
    /// If the server-reported progress percentage does not change for this
    /// duration, the job is considered stalled and will be failed.
    ///
    /// - 300 seconds (5 minutes) matches `RetryConstants.stallDetectionSeconds`
    /// - Research: Google Cloud ML Engine uses 5-minute stall detection
    /// - This is the PRIMARY safety mechanism replacing the 180s hard timeout
    public static let stallTimeoutSeconds: TimeInterval = 300

    /// Minimum progress delta (percentage points) to consider "making progress".
    /// Progress changes smaller than this are treated as stall.
    ///
    /// - 0.1% prevents floating-point noise from resetting the stall timer
    /// - Nerfstudio reports progress at ~0.003% per step (step 1/30000)
    ///   so any single step produces 0.003% which is below this threshold
    ///   but multiple steps within the poll interval will exceed it
    public static let stallMinProgressDelta: Double = 0.1

    // =========================================================================
    // MARK: - Absolute Safety Cap
    // =========================================================================

    /// Absolute maximum timeout in seconds.
    /// Even if progress is being reported, the job will fail after this duration.
    /// This is a safety net against infinite loops or runaway processes.
    ///
    /// - 7200 seconds (2 hours) covers worst-case: 15min video + slow GPU
    /// - Calculation: upload (15min) + SfM (30min) + training (45min) + export (5min) + buffer = ~2h
    /// - This is the SECONDARY safety mechanism
    public static let absoluteMaxTimeoutSeconds: TimeInterval = 7200

    // =========================================================================
    // MARK: - Polling Configuration
    // =========================================================================

    /// Poll interval during active processing (seconds).
    /// How often the client checks server for progress updates.
    ///
    /// - 3 seconds matches `ContractConstants.PROGRESS_REPORT_INTERVAL_SECONDS`
    /// - Research: Nielsen Norman Group — 1-10s intervals for progress feedback
    /// - Too fast (< 1s): unnecessary network load on mobile
    /// - Too slow (> 10s): stale progress display, poor UX
    public static let pollIntervalSeconds: TimeInterval = 3.0

    /// Poll interval during queued state (seconds).
    /// Longer interval when job is waiting — no active processing to monitor.
    ///
    /// - 5 seconds matches `APIContractConstants.POLLING_INTERVAL_QUEUED`
    public static let pollIntervalQueuedSeconds: TimeInterval = 5.0

    // =========================================================================
    // MARK: - iOS Background Handling
    // =========================================================================

    /// Background poll interval (seconds).
    /// When the app enters background, reduce polling frequency to conserve
    /// battery and comply with iOS background execution limits.
    ///
    /// - 30 seconds: matches heartbeat interval
    /// - iOS allows ~30s of background execution after entering background
    /// - Beyond that, use BGProcessingTask for extended background work
    public static let backgroundPollIntervalSeconds: TimeInterval = 30.0

    /// Background grace period (seconds).
    /// After entering background, continue polling for this duration before
    /// switching to push-notification-based updates (future).
    ///
    /// - 180 seconds (3 minutes): iOS typically allows ~180s with beginBackgroundTask
    /// - After this, the system may suspend the app
    public static let backgroundGracePeriodSeconds: TimeInterval = 180.0

    // =========================================================================
    // MARK: - Progress Stages (Closed Set)
    // =========================================================================

    /// Valid progress stage identifiers (must match server-side stages).
    /// Used for validation — reject unknown stages from the server.
    public static let validStages: Set<String> = [
        "queued",
        "sfm_extract",
        "sfm_match",
        "sfm_reconstruct",
        "gs_train",
        "export",
        "packaging",
        "complete",
    ]

    // =========================================================================
    // MARK: - Specifications (SSOT)
    // =========================================================================

    public static let stallTimeoutSpec = ThresholdSpec(
        ssotId: "PipelineTimeoutConstants.stallTimeoutSeconds",
        name: "Pipeline Stall Timeout",
        unit: .seconds,
        category: .safety,
        min: 60.0,
        max: 900.0,
        defaultValue: stallTimeoutSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "5 minutes without progress change triggers stall failure"
    )

    public static let absoluteMaxTimeoutSpec = ThresholdSpec(
        ssotId: "PipelineTimeoutConstants.absoluteMaxTimeoutSeconds",
        name: "Pipeline Absolute Max Timeout",
        unit: .seconds,
        category: .safety,
        min: 600.0,
        max: 14400.0,
        defaultValue: absoluteMaxTimeoutSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "2 hours absolute cap, covers worst-case 15min video on slow GPU"
    )

    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(stallTimeoutSpec),
        .threshold(absoluteMaxTimeoutSpec),
    ]
}
```

### §3.2 PipelineRunner — Replace Hard Timeout with Stall Detection

**File**: `Core/Pipeline/PipelineRunner.swift`

Replace BOTH occurrences of `Timeout.withTimeout(seconds: 180)` with the new stall-aware polling loop.

**Key Design Decisions**:
1. The outer `Timeout.withTimeout(seconds: 180)` is REMOVED entirely.
2. `pollAndDownload()` gains stall detection logic internally.
3. `absoluteMaxTimeoutSeconds` serves as the safety net (previously `180`).
4. Progress is forwarded to the caller for UI display.

```swift
// REPLACE the current pollAndDownload method:

/// Polls for job completion with stall detection.
/// - If progress does not change for `stallTimeoutSeconds`, throws `FailReason.stalledProcessing`
/// - If total elapsed exceeds `absoluteMaxTimeoutSeconds`, throws `FailReason.timeout`
/// - Parameter progressHandler: Optional closure called with (percentage: Double, stage: String, message: String)
private func pollAndDownload(
    jobId: String,
    progressHandler: ((Double, String, String) -> Void)? = nil
) async throws -> (data: Data, format: ArtifactFormat) {

    let pollInterval = PipelineTimeoutConstants.pollIntervalSeconds
    let queuedPollInterval = PipelineTimeoutConstants.pollIntervalQueuedSeconds
    let stallTimeout = PipelineTimeoutConstants.stallTimeoutSeconds
    let absoluteMax = PipelineTimeoutConstants.absoluteMaxTimeoutSeconds
    let minDelta = PipelineTimeoutConstants.stallMinProgressDelta

    let startTime = Date()
    var lastProgressValue: Double = -1.0
    var lastProgressChangeTime = Date()

    while true {
        // 1. Absolute timeout check
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > absoluteMax {
            throw FailReason.timeout
        }

        // 2. Poll server
        let status = try await self.remoteClient.pollStatus(jobId: jobId)

        switch status {
        case .completed:
            return try await self.remoteClient.download(jobId: jobId)

        case .failed(let reason):
            throw RemoteB1ClientError.jobFailed(reason)

        case .pending(let progress):
            // Queued — use longer poll interval, no stall detection yet
            if let p = progress {
                progressHandler?(p, "queued", "Waiting in queue")
            }
            try await Task.sleep(nanoseconds: UInt64(queuedPollInterval * 1_000_000_000))

        case .processing(let progress):
            let currentProgress = progress ?? 0.0

            // Forward progress to UI
            progressHandler?(currentProgress, "processing", "Processing...")

            // 3. Stall detection: has progress changed?
            let delta = abs(currentProgress - lastProgressValue)
            if delta >= minDelta {
                // Progress is moving — reset stall timer
                lastProgressValue = currentProgress
                lastProgressChangeTime = Date()
            } else {
                // Progress stalled — check stall timeout
                let stallDuration = Date().timeIntervalSince(lastProgressChangeTime)
                if stallDuration > stallTimeout {
                    throw FailReason.stalledProcessing
                }
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}
```

Then update BOTH `runGenerate` methods to remove the `Timeout.withTimeout(seconds: 180)` wrapper:

```swift
// In runGenerate(request:outputRoot:) — REPLACE lines 88-93:
// OLD:
//   let (plyData, _) = try await Timeout.withTimeout(seconds: 180) { ... }
// NEW:
let assetId = try await self.remoteClient.upload(videoURL: videoURL)
let jobId = try await self.remoteClient.startJob(assetId: assetId)
let (plyData, format) = try await self.pollAndDownload(jobId: jobId)

// In runGenerate(request:) — REPLACE lines 245-259:
// OLD:
//   let artifact: ArtifactRef = try await Timeout.withTimeout(seconds: 180) { ... }
// NEW:
let assetId = try await self.remoteClient.upload(videoURL: videoURL)
let jobId = try await self.remoteClient.startJob(assetId: assetId)
let (splatData, format) = try await self.pollAndDownload(jobId: jobId)
let url = try self.writeSplatToDocuments(data: splatData, format: format, jobId: jobId)
let artifact = ArtifactRef(localPath: url, format: format)
```

Also add a new `catch` clause for `FailReason.stalledProcessing`:

```swift
} catch let error as FailReason where error == .stalledProcessing {
    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
    #if canImport(AVFoundation)
    PlainAuditLog.shared.append(AuditEntry(
        timestamp: WallClock.now(),
        eventType: "generate_fail",
        detailsJson: "{\"reason\":\"stalled_processing\",\"elapsedMs\":\(elapsed)}"
    ))
    #endif
    return .fail(reason: .stalledProcessing, elapsedMs: elapsed)
}
```

### §3.3 FailReason Mapping Update

**File**: `Core/Pipeline/PipelineRunner.swift` — `mapRemoteB1ClientError` method

The existing `FailReason` enum already has `.stalledProcessing` and `.timeout`. No changes needed to the enum. But ensure `PipelineRunner.mapRemoteB1ClientError` does NOT need updating since stall detection happens client-side via `FailReason` directly, not through `RemoteB1ClientError`.

### §3.4 PipelineDemoViewModel — Display Real Progress

**File**: `App/Demo/PipelineDemoViewModel.swift`

The `UIState.generating(progress: Double?)` already supports optional progress. No changes needed to the enum. The `PipelineRunner.runGenerate` returns `GenerateResult` which doesn't expose intermediate progress. For real-time UI updates, the ViewModel should use a separate polling mechanism OR the runner should expose a progress stream.

**Recommended approach**: For now, keep the ViewModel unchanged. The `ProgressEstimator.calculatePerceivedProgress()` can be used in a future PR to transform raw progress into smooth UI values. The critical path in this PR is making the pipeline NOT fail after 180s.

### §3.5 iOS Background Handling

**File**: `Core/Pipeline/PipelineRunner.swift`

When the iOS app goes to background during generation, the system may suspend network operations. Add background task registration:

```swift
#if canImport(UIKit)
import UIKit
#endif

// Inside pollAndDownload, before the while loop:
#if canImport(UIKit)
var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "PipelinePoll") {
    // Cleanup: system is about to suspend us
    if backgroundTaskId != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
}
defer {
    if backgroundTaskId != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
    }
}
#endif
```

**IMPORTANT**: This uses `beginBackgroundTask` which gives ~30 seconds (iOS 13+) to ~180 seconds of background execution. For truly long jobs, the user must keep the app in foreground. A future PR should add push notification support for background completion.

---

## §4 CHANGE 3 — CONTRACT & DOCUMENTATION UPDATES

### §4.1 WHITEBOX.md Update

**File**: `docs/WHITEBOX.md`

```markdown
## Hard Constraints

- 仅 B1 pipeline（不启用 D1）
- ~~≤180s 硬约束（超时必须 fail-fast）~~
- Stall-based timeout: 5 minutes without progress change → fail-fast
- Absolute safety cap: 2 hours maximum total processing time
- 不测试画质、不测试体验质量
```

### §4.2 ACCEPTANCE.md Update

**File**: `docs/ACCEPTANCE.md`

```markdown
### Module 2: Generate — Pass

- ~~单 pipeline 在 ≤180s 内返回~~
- Pipeline returns success or failure with real-time progress reporting
- Stall detection: fails if no progress for 5 minutes (not if slow but moving)
- 返回结果（.splat / .ply）或明确失败原因（已记录）
- 超时必须 fail-fast（不卡死）
```

### §4.3 SSOT Constants Update

**File**: `docs/constitution/SSOT_CONSTANTS.md`

Add new rows:

```markdown
| PipelineTimeoutConstants.stallTimeoutSeconds | 300 | seconds | safety | 60.0 | 900.0 | 300 | warn | reject | 5分钟无进度变化判定卡死 |
| PipelineTimeoutConstants.absoluteMaxTimeoutSeconds | 7200 | seconds | safety | 600.0 | 14400.0 | 7200 | warn | reject | 2小时绝对上限，覆盖最差情况 |
| PipelineTimeoutConstants.pollIntervalSeconds | 3.0 | seconds | performance | 1.0 | 10.0 | 3.0 | warn | reject | 处理中轮询间隔，平衡网络负载与实时性 |
| PipelineTimeoutConstants.backgroundPollIntervalSeconds | 30.0 | seconds | performance | 10.0 | 120.0 | 30.0 | warn | reject | 后台轮询间隔，节省电量 |
```

### §4.4 Drift Registry Update

**File**: `docs/drift/DRIFT_REGISTRY.md`

Add new drift entry:

```markdown
| D011 | PR-PROGRESS | PipelineRunner.timeout | 180s hard | stall-based (300s no-progress + 7200s absolute) | RELAXED | 180s incompatible with 900s max recording | Cross-module | 2026-02-XX |
```

---

## §5 CHANGE 4 — CROSS-PLATFORM GUARDRAILS

### §5.1 Linux Compatibility

All new Swift code MUST compile on Linux. Rules:
- `PipelineTimeoutConstants.swift` uses only `Foundation` — ✅ safe
- `PipelineRunner.swift` background task code is guarded with `#if canImport(UIKit)` — ✅ safe
- No new Apple-only framework imports in `Core/` directory
- The `UIApplication.shared.beginBackgroundTask` call is iOS-only and guarded

### §5.2 Audit Trail

Every timeout/stall decision MUST be logged via `PlainAuditLog`. The existing audit entries for `generate_fail` with `reason: "timeout"` should be extended:

```swift
// For stall failure:
detailsJson: "{\"reason\":\"stalled_processing\",\"stallDurationSeconds\":\(stallDuration),\"lastProgress\":\(lastProgressValue),\"elapsedMs\":\(elapsed)}"

// For absolute timeout:
detailsJson: "{\"reason\":\"absolute_timeout\",\"elapsedMs\":\(elapsed),\"lastProgress\":\(lastProgressValue)}"
```

### §5.3 FakeRemoteB1Client Update

**File**: `Core/Pipeline/FakeRemoteB1Client.swift`

The fake client currently returns `.completed` immediately from `pollStatus`. Update it to simulate progress:

```swift
final class FakeRemoteB1Client: RemoteB1Client {
    private var pollCount = 0
    private static let fixedAssetId = "fake-asset-00000000"
    // ... (fixedPlyContent unchanged)

    func pollStatus(jobId: String) async throws -> JobStatus {
        pollCount += 1
        if pollCount <= 2 {
            return .processing(progress: Double(pollCount) * 30.0)
        } else if pollCount == 3 {
            return .processing(progress: 90.0)
        } else {
            return .completed
        }
    }

    // ... (other methods unchanged)
}
```

### §5.4 Test Requirements

**New test file**: `Tests/Pipeline/StallDetectionTests.swift`

```swift
// Test 1: Normal completion — progress moves, no stall
// Test 2: Stall detection — progress stops, fails after stallTimeoutSeconds
// Test 3: Absolute timeout — progress moves but too slow, hits absoluteMaxTimeoutSeconds
// Test 4: Queued state — no stall detection during queued (only during processing)
// Test 5: Progress delta threshold — tiny changes below stallMinProgressDelta don't reset timer
// Test 6: Background transition — verify poll interval changes (iOS only)
```

**New test file**: `Tests/Pipeline/NerfstudioProgressParsingTests.swift` (server-side, Python)

```python
# Test 1: Parse "Step 1000/30000" → 40 + (1000/30000 * 55) = 41.83%
# Test 2: Parse "Feature extraction: 50/200" → (50/200) * 15 = 3.75%
# Test 3: Malformed output → no crash, progress stays at last known value
# Test 4: Empty output → progress stays at 0, eventually stall-detected
# Test 5: Progress callback is throttled (no DB write for <1% changes)
```

---

## §6 MIGRATION CHECKLIST

### §6.1 Breaking Changes

| Change | Impact | Migration |
|--------|--------|-----------|
| `Timeout.withTimeout(seconds: 180)` removed | `PipelineRunner` no longer has hard timeout | Replaced by stall detection in `pollAndDownload` |
| `nerfstudio.py` `TIMEOUT_SECONDS = 180` removed | Server no longer kills nerfstudio after 3min | Replaced by per-phase timeouts (30min SfM + 60min training + 5min export) |
| Job model gains `progress_stage`, `progress_message` columns | Database schema change | Add columns with `ALTER TABLE jobs ADD COLUMN progress_stage VARCHAR; ALTER TABLE jobs ADD COLUMN progress_message VARCHAR;` |
| Pipeline protocol gains `on_progress` parameter | All pipelines must accept new optional parameter | Default `None` — backward compatible |

### §6.2 File Change Summary

| File | Action | Lines Changed (est.) |
|------|--------|---------------------|
| `server/app/pipelines/base.py` | EDIT | +15 |
| `server/app/pipelines/nerfstudio.py` | REWRITE | ~200 |
| `server/app/pipelines/dummy.py` | EDIT | +20 |
| `server/app/services/job_service.py` | EDIT | +15 |
| `server/app/models.py` | EDIT | +3 |
| `server/app/api/handlers/job_handlers.py` | EDIT | +15, -5 |
| `Core/Constants/PipelineTimeoutConstants.swift` | NEW | ~120 |
| `Core/Pipeline/PipelineRunner.swift` | EDIT | +60, -20 |
| `Core/Pipeline/FakeRemoteB1Client.swift` | EDIT | +10, -2 |
| `docs/WHITEBOX.md` | EDIT | +3, -1 |
| `docs/ACCEPTANCE.md` | EDIT | +3, -1 |
| `docs/constitution/SSOT_CONSTANTS.md` | EDIT | +4 |
| `docs/drift/DRIFT_REGISTRY.md` | EDIT | +1 |
| `Tests/Pipeline/StallDetectionTests.swift` | NEW | ~150 |

### §6.3 Verification Commands

```bash
# 1. Swift compilation (cross-platform)
swift build 2>&1 | grep -i error

# 2. Swift tests
swift test --filter StallDetection

# 3. Python server tests
cd server && python -m pytest tests/ -v

# 4. Lint: no hardcoded 180 remaining
grep -rn "180" Core/Pipeline/PipelineRunner.swift
# Expected: 0 matches (only line numbers may contain 180)

grep -rn "TIMEOUT_SECONDS = 180" server/app/pipelines/
# Expected: 0 matches

# 5. Constants scan: no magic numbers
grep -rn "= 300\|= 7200\|= 3\.0\|= 5\.0\|= 30\.0" Core/Constants/PipelineTimeoutConstants.swift
# Expected: matches only in PipelineTimeoutConstants.swift

# 6. Cross-platform guard scan
grep -rn "UIKit\|UIApplication" Core/Pipeline/
# Expected: only inside #if canImport(UIKit) blocks
```

---

## §7 NON-GOALS (Explicitly Out of Scope)

- **WebSocket upgrade**: Polling is sufficient for this stage. WebSocket can be added later.
- **Push notifications for background completion**: Requires APNs setup. Future PR.
- **Server-sent events (SSE)**: More complex than polling for mobile clients. Future PR.
- **Dynamic timeout based on video length**: The stall-based approach makes this unnecessary — any video length is supported as long as progress is being made.
- **GPU utilization monitoring**: Would be nice but adds server-side complexity. Stall detection is sufficient.
- **Multi-GPU support**: Out of scope.
- **ProgressEstimator integration**: The `ProgressEstimator` already works with real data. Once the server sends real progress, it will automatically improve. No code changes needed in `ProgressEstimator`.

---

## §8 RISK ASSESSMENT

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Nerfstudio output format changes between versions | Medium | Progress parsing breaks → fallback to 0% | Regex patterns are lenient; unmatched lines are silently ignored; stall detection still works |
| Server DB write bottleneck from frequent progress updates | Low | Slow progress writes | 1% minimum increment throttle; SQLite WAL mode handles concurrent reads |
| iOS background suspension during processing | High | Polling stops → user thinks app crashed | `beginBackgroundTask` gives 180s grace; clear UI message: "Keep app open during processing" |
| Stall false positive on slow GPU | Low | Job killed while actually making progress | 5-minute stall window is very generous; `stallMinProgressDelta = 0.1%` is tiny |
| Network partition between client and server | Medium | Client can't poll → stall timer ticks | This is correct behavior: if client can't reach server for 5 min, failing is the right call |

---

**END OF DOCUMENT**
