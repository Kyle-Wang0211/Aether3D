from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="forbid",
    )

    # ========== API ==========
    api_key: str = ""
    debug: bool = False

    # ========== Database ==========
    database_url: str = "sqlite:///./aether3d.db"

    # ========== Storage Paths (RAW, from env) ==========
    upload_dir: str = "storage/uploads"
    artifact_dir: str = "storage/artifacts"
    nerfstudio_work_dir: str = "storage/nerfstudio_work"

    # ========== Retention Policy (days, 0 = no cleanup) ==========
    uploads_retention_days: int = 7
    artifacts_retention_days: int = 0
    ns_work_retention_days: int = 1

    # ========== Upload limits ==========
    max_upload_mb: int = 500

    # ========== Resolved Paths (runtime only) ==========
    upload_path: Path = Path()
    artifact_path: Path = Path()
    nerfstudio_work_path: Path = Path()

    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        # Base dir = server/
        base_dir = Path(__file__).parent.parent.parent

        self.upload_path = (base_dir / self.upload_dir).resolve()
        self.artifact_path = (base_dir / self.artifact_dir).resolve()
        self.nerfstudio_work_path = (base_dir / self.nerfstudio_work_dir).resolve()


settings = Settings()

