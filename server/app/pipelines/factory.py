from app.pipelines.aether3dgs import Aether3DGSPipeline
from app.pipelines.dummy import DummyPipeline
from app.pipelines.nerfstudio import NerfstudioPipeline


def create_pipeline(pipeline_type: str = "aether3dgs"):
    """
    Create pipeline instance.
    
    Args:
        pipeline_type: "aether3dgs", "dummy", or "nerfstudio"
    
    Returns:
        Pipeline instance
    """
    if pipeline_type in {"aether3dgs", "aether", "self"}:
        return Aether3DGSPipeline()
    elif pipeline_type == "dummy":
        return DummyPipeline()
    elif pipeline_type == "nerfstudio":
        return NerfstudioPipeline()
    else:
        raise ValueError(f"Unknown pipeline type: {pipeline_type}")
