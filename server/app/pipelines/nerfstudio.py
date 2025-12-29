import asyncio
import shutil
import subprocess
from pathlib import Path
from typing import Optional, Tuple

from app.core.errors import ProcessingFailedError, TimeoutError
from app.core.storage import ensure_directory, remove_file


class NerfstudioPipeline:
    """Nerfstudio pipeline for processing video to 3DGS."""
    
    ARTIFACT_FORMAT = "ply"
    TIMEOUT_SECONDS = 180
    
    async def process(self, input_path: Path, output_path: Path, job_id: str) -> Tuple[str, str]:
        """
        Process input using nerfstudio.
        
        Returns:
            Tuple of (artifact_path, artifact_format)
        """
        # Check if ns-process-data command exists
        if not shutil.which("ns-process-data"):
            raise ProcessingFailedError(
                "nerfstudio not available: 'ns-process-data' command not found"
            )
        
        # Create work directory
        work_dir = output_path.parent / f"ns_work_{job_id}"
        ensure_directory(work_dir)
        
        try:
            # Run ns-process-data with timeout
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
            
            try:
                stdout, stderr = await asyncio.wait_for(
                    process.communicate(),
                    timeout=self.TIMEOUT_SECONDS,
                )
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
                raise TimeoutError(f"nerfstudio processing timed out after {self.TIMEOUT_SECONDS}s")
            
            if process.returncode != 0:
                error_msg = stderr.decode("utf-8", errors="ignore") if stderr else "Unknown error"
                raise ProcessingFailedError(f"nerfstudio processing failed: {error_msg}")
            
            # Find output PLY file
            ply_file = self._find_output_ply(work_dir)
            if not ply_file:
                raise ProcessingFailedError("nerfstudio did not produce output PLY file")
            
            # Copy to artifact directory
            artifact_filename = f"{job_id}.ply"
            artifact_path = output_path.parent / artifact_filename
            shutil.copy2(ply_file, artifact_path)
            
            return str(artifact_path), self.ARTIFACT_FORMAT
        
        finally:
            # Cleanup work directory
            remove_file(work_dir)
    
    def _find_output_ply(self, work_dir: Path) -> Optional[Path]:
        """Find output PLY file in work directory."""
        for pattern in ["*.ply", "**/*.ply"]:
            for ply_file in work_dir.glob(pattern):
                if ply_file.is_file():
                    return ply_file
        return None

