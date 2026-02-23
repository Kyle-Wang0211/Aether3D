from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional, Protocol, Tuple


@dataclass
class ProgressUpdate:
    """Progress update for pipeline processing.
    
    Guarantees monotonic semantics: percent and stage must never go backwards.
    """
    percent: Optional[float]  # 0.0 to 100.0, or None if not available
    stage: str  # Stage identifier: "sfm", "train", "export", etc.
    message: str  # Human-readable message (max 512 chars)
    ts: datetime  # Server time, timezone-aware
    
    def __post_init__(self):
        """Validate progress update."""
        if self.percent is not None:
            if self.percent < 0.0 or self.percent > 100.0:
                raise ValueError(f"percent must be in [0.0, 100.0], got {self.percent}")
        if len(self.message) > 512:
            raise ValueError(f"message must be <= 512 chars, got {len(self.message)}")


class Pipeline(Protocol):
    """Pipeline protocol for processing video to 3D artifact."""
    
    async def process(
        self,
        input_path: Path,
        output_path: Path,
        job_id: str,
        on_progress: Optional[Callable[[ProgressUpdate], None]] = None,
    ) -> Tuple[str, str]:
        """
        Process input video and generate artifact.
        
        Args:
            input_path: Path to input video file
            output_path: Path where artifact should be saved
            job_id: Job ID for naming output file
            on_progress: Optional callback for progress updates.
                        Called with ProgressUpdate whenever progress changes.
                        Must guarantee monotonic semantics (percent/stage never decrease).
        
        Returns:
            Tuple of (artifact_path, artifact_format)
        
        Raises:
            AppError: If processing fails
        """
        ...

