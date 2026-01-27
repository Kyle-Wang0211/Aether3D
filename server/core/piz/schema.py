"""
PIZ Detection Schema (Python Pydantic)
PR1 PIZ Detection - Closed-World Schema

Mirrors Swift PIZReport exactly (same field names, same enums).
Enforces extra="forbid" to reject unknown fields.
"""

from pydantic import BaseModel, Field, validator
from typing import List, Literal
from datetime import datetime
from enum import Enum


class GateRecommendation(str, Enum):
    """Gate recommendation enum (closed set)."""
    ALLOW_PUBLISH = "ALLOW_PUBLISH"
    BLOCK_PUBLISH = "BLOCK_PUBLISH"
    RECAPTURE = "RECAPTURE"
    INSUFFICIENT_DATA = "INSUFFICIENT_DATA"


class RecapturePriority(str, Enum):
    """Recapture suggestion priority."""
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"


class ComputePhase(str, Enum):
    """Compute phase enum."""
    REALTIME_ESTIMATE = "realtime_estimate"
    DELAYED_REFINEMENT = "delayed_refinement"
    FINALIZED = "finalized"


class BoundingBox(BaseModel):
    """Bounding box for a region (grid coordinates)."""
    minRow: int = Field(..., alias="minRow")
    maxRow: int = Field(..., alias="maxRow")
    minCol: int = Field(..., alias="minCol")
    maxCol: int = Field(..., alias="maxCol")
    
    class Config:
        extra = "forbid"


class Point(BaseModel):
    """Point in grid coordinates."""
    row: float
    col: float
    
    class Config:
        extra = "forbid"


class Vector(BaseModel):
    """Vector in grid coordinates."""
    dx: float
    dy: float
    
    class Config:
        extra = "forbid"


class PIZRegion(BaseModel):
    """Detected PIZ region."""
    id: str
    pixelCount: int = Field(..., alias="pixelCount")
    areaRatio: float = Field(..., ge=0.0, le=1.0, alias="areaRatio")
    bbox: BoundingBox
    centroid: Point
    principalDirection: Vector = Field(..., alias="principalDirection")
    severityScore: float = Field(..., ge=0.0, le=1.0, alias="severityScore")
    
    class Config:
        extra = "forbid"


class RecaptureSuggestion(BaseModel):
    """Structured recapture suggestion."""
    suggestedRegions: List[str] = Field(..., alias="suggestedRegions")
    priority: RecapturePriority
    reason: str
    
    class Config:
        extra = "forbid"


class PIZReport(BaseModel):
    """PIZ Detection Report (v1)."""
    schemaVersion: int = Field(..., alias="schemaVersion", ge=1)
    foundationVersion: str = Field(..., alias="foundationVersion")
    connectivityMode: str = Field(..., alias="connectivityMode")
    heatmap: List[List[float]] = Field(..., min_items=32, max_items=32)
    regions: List[PIZRegion]
    globalTrigger: bool = Field(..., alias="globalTrigger")
    localTriggerCount: int = Field(..., alias="localTriggerCount")
    gateRecommendation: GateRecommendation = Field(..., alias="gateRecommendation")
    recaptureSuggestion: RecaptureSuggestion = Field(..., alias="recaptureSuggestion")
    assetId: str = Field(..., alias="assetId")
    timestamp: datetime
    computePhase: ComputePhase = Field(..., alias="computePhase")
    
    @validator("heatmap")
    def validate_heatmap_size(cls, v):
        """Validate heatmap is 32x32."""
        if len(v) != 32:
            raise ValueError("Heatmap must be 32 rows")
        for row in v:
            if len(row) != 32:
                raise ValueError("Heatmap must be 32 columns")
        return v
    
    @validator("connectivityMode")
    def validate_connectivity_mode(cls, v):
        """Validate connectivity mode is FOUR."""
        if v != "FOUR":
            raise ValueError(f"Connectivity mode must be FOUR, got {v}")
        return v
    
    class Config:
        extra = "forbid"  # Closed-world: reject unknown fields
