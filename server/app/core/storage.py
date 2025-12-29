import os
import shutil
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, Optional

from app.core.config import settings


def ensure_directory(path: Path) -> None:
    """Ensure directory exists, create if not."""
    path.mkdir(parents=True, exist_ok=True)


def cleanup_old_files(directory: Path, retention_days: int) -> int:
    """
    Clean up files older than retention_days.
    Returns number of files deleted.
    If retention_days is 0, skip cleanup.
    """
    if retention_days == 0:
        return 0
    
    if not directory.exists():
        return 0
    
    cutoff_time = datetime.now() - timedelta(days=retention_days)
    deleted_count = 0
    
    for item in directory.iterdir():
        if item.is_file():
            mtime = datetime.fromtimestamp(item.stat().st_mtime)
            if mtime < cutoff_time:
                try:
                    item.unlink()
                    deleted_count += 1
                except OSError:
                    pass
        elif item.is_dir():
            mtime = datetime.fromtimestamp(item.stat().st_mtime)
            if mtime < cutoff_time:
                try:
                    shutil.rmtree(item)
                    deleted_count += 1
                except OSError:
                    pass
    
    return deleted_count


def cleanup_storage() -> Dict[str, int]:
    """Clean up old files according to retention policy."""
    result = {
        "uploads": 0,
        "artifacts": 0,
        "nerfstudio_work": 0,
    }
    
    if settings.uploads_retention_days > 0:
        result["uploads"] = cleanup_old_files(settings.upload_path, settings.uploads_retention_days)
    
    if settings.artifacts_retention_days > 0:
        result["artifacts"] = cleanup_old_files(settings.artifact_path, settings.artifacts_retention_days)
    
    if settings.ns_work_retention_days > 0:
        result["nerfstudio_work"] = cleanup_old_files(settings.nerfstudio_work_path, settings.ns_work_retention_days)
    
    return result


def save_upload_file(file_content: bytes, filename: str) -> Path:
    """Save uploaded file to upload directory."""
    ensure_directory(settings.upload_path)
    file_path = settings.upload_path / filename
    file_path.write_bytes(file_content)
    return file_path


def save_artifact_file(file_content: bytes, filename: str) -> Path:
    """Save artifact file to artifact directory."""
    ensure_directory(settings.artifact_path)
    file_path = settings.artifact_path / filename
    file_path.write_bytes(file_content)
    return file_path


def get_artifact_file_path(filename: str) -> Optional[Path]:
    """Get artifact file path if exists."""
    file_path = settings.artifact_path / filename
    if file_path.exists():
        return file_path
    return None


def remove_file(file_path: Path) -> None:
    """Remove file if exists."""
    if file_path.exists():
        try:
            if file_path.is_file():
                file_path.unlink()
            elif file_path.is_dir():
                shutil.rmtree(file_path)
        except OSError:
            pass

