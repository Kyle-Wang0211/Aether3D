import asyncio
from pathlib import Path
from typing import Tuple

from app.core.errors import ProcessingFailedError
from app.core.storage import save_artifact_file


class DummyPipeline:
    """Dummy pipeline that generates a valid PLY file for testing."""
    
    ARTIFACT_FORMAT = "ply"
    
    async def process(self, input_path: Path, output_path: Path, job_id: str) -> Tuple[str, str]:
        """
        Process input and generate a valid PLY file.
        
        Returns:
            Tuple of (artifact_path, artifact_format)
        """
        # Simulate processing time
        await asyncio.sleep(2.0)
        
        # Generate valid PLY file with at least 10 vertices (300 for stable 4KB+ size)
        ply_content = self._generate_ply_content(vertex_count=300)
        
        # Save artifact
        filename = f"{job_id}.ply"
        artifact_path = save_artifact_file(ply_content, filename)
        
        # Validate artifact (Fail-Fast)
        self._validate_artifact(artifact_path, self.ARTIFACT_FORMAT)
        
        return str(artifact_path), self.ARTIFACT_FORMAT
    
    def _generate_ply_content(self, vertex_count: int = 10) -> bytes:
        """Generate valid PLY file content."""
        # Ensure at least 10 vertices
        if vertex_count < 10:
            vertex_count = 10
        
        # Generate PLY header and vertex data
        header_lines = [
            b"ply",
            b"format ascii 1.0",
            b"element vertex " + str(vertex_count).encode(),
            b"property float x",
            b"property float y",
            b"property float z",
            b"property float nx",
            b"property float ny",
            b"property float nz",
            b"property uchar red",
            b"property uchar green",
            b"property uchar blue",
            b"end_header",
        ]
        
        # Generate vertex data
        vertices = []
        for i in range(vertex_count):
            x = float(i * 0.1)
            y = float(i * 0.2)
            z = float(i * 0.3)
            nx = 0.0
            ny = 0.0
            nz = 1.0
            r = min(255, i * 25)
            g = min(255, (i + 5) * 20)
            b = min(255, (i + 10) * 15)
            vertices.append(f"{x} {y} {z} {nx} {ny} {nz} {r} {g} {b}\n".encode())
        
        # Combine header and vertices
        content = b"\n".join(header_lines) + b"\n" + b"".join(vertices)
        
        return content
    
    def _validate_artifact(self, artifact_path: Path, artifact_format: str) -> None:
        """
        Validate artifact meets minimum requirements (Fail-Fast).
        
        Raises:
            ProcessingFailedError: If validation fails
        """
        # Check file extension matches format
        if artifact_path.suffix != f".{artifact_format}":
            raise ProcessingFailedError(
                f"Artifact extension '{artifact_path.suffix}' does not match format '{artifact_format}'"
            )
        
        # Check file exists and has content
        if not artifact_path.exists():
            raise ProcessingFailedError(f"Artifact file not found: {artifact_path}")
        
        file_size = artifact_path.stat().st_size
        if file_size < 1024:
            raise ProcessingFailedError(
                f"Artifact file size {file_size} bytes is less than minimum 1024 bytes"
            )
        
        # Check file starts with "ply" header
        with open(artifact_path, "rb") as f:
            header = f.read(3)
            if header != b"ply":
                raise ProcessingFailedError(
                    f"Artifact file does not start with 'ply' header, got: {header}"
                )
        
        # Check vertex count (parse PLY header)
        vertex_count = self._parse_vertex_count(artifact_path)
        if vertex_count < 10:
            raise ProcessingFailedError(
                f"Artifact vertex count {vertex_count} is less than minimum 10"
            )
    
    def _parse_vertex_count(self, ply_path: Path) -> int:
        """Parse vertex count from PLY header."""
        try:
            with open(ply_path, "rb") as f:
                for line in f:
                    line_str = line.decode("utf-8", errors="ignore").strip()
                    if line_str.startswith("element vertex"):
                        parts = line_str.split()
                        if len(parts) >= 3:
                            return int(parts[2])
        except (ValueError, IndexError, UnicodeDecodeError):
            pass
        return 0

