from pathlib import Path
from typing import Protocol, Tuple


class Pipeline(Protocol):
    """Pipeline protocol for processing video to 3D artifact."""
    
    def process(self, input_path: Path, output_path: Path, job_id: str) -> Tuple[str, str]:
        """
        Process input video and generate artifact.
        
        Args:
            input_path: Path to input video file
            output_path: Path where artifact should be saved
            job_id: Job ID for naming output file
        
        Returns:
            Tuple of (artifact_path, artifact_format)
        
        Raises:
            AppError: If processing fails
        """
        ...

