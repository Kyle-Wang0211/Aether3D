from typing import Optional

from sqlalchemy.orm import Session

from app.models import Asset


class AssetRepository:
    def __init__(self, db: Session):
        self.db = db

    def create(self, asset_id: str, file_path: str, file_size: int) -> Asset:
        """Create a new asset."""
        asset = Asset(
            id=asset_id,
            file_path=file_path,
            file_size=file_size,
        )
        self.db.add(asset)
        self.db.commit()
        self.db.refresh(asset)
        return asset

    def get_by_id(self, asset_id: str) -> Optional[Asset]:
        """Get asset by ID."""
        return (
            self.db.query(Asset)
            .filter(Asset.id == asset_id)
            .first()
        )

    def delete(self, asset_id: str) -> bool:
        """Delete asset by ID."""
        asset = (
            self.db.query(Asset)
            .filter(Asset.id == asset_id)
            .first()
        )
        if not asset:
            return False

        self.db.delete(asset)
        self.db.commit()
        return True
