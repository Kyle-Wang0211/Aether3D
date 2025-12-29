from app.pipelines.dummy import DummyPipeline
from app.pipelines.nerfstudio import NerfstudioPipeline


def create_pipeline(pipeline_type: str = "dummy"):
    """
    Create pipeline instance.
    
    Args:
        pipeline_type: "dummy" or "nerfstudio"
    
    Returns:
        Pipeline instance
    """
    if pipeline_type == "dummy":
        return DummyPipeline()
    elif pipeline_type == "nerfstudio":
        return NerfstudioPipeline()
    else:
        raise ValueError(f"Unknown pipeline type: {pipeline_type}")

