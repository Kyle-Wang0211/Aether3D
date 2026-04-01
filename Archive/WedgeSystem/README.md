# Wedge System Archive

**Archived**: 2026-02-26
**Reason**: Replaced by Point Cloud + OIR (Order-Independent Rendering) pipeline

## What Was This

The Wedge Guidance System rendered 3D prism geometry over ARKit mesh during scanning.
It provided grayscale evidence visualization (S0-S5), flip animations, ripple propagation,
and 6-pass Metal rendering with PBR lighting.

**Key characteristics**:
- 6-pass Metal pipeline (fill + border + metallic + color + AO + post)
- LOD 4 levels: 44x vertex expansion per triangle at full LOD
- ~39MB GPU memory (triple-buffered vertex/index/uniform/per-triangle)
- Patch identity stabilization (4K anchors + 50K aliases)
- Flip animation + BFS ripple propagation on spatial hash adjacency

## Original File Paths

### Swift Source
| Archive Path | Original Path |
|-------------|--------------|
| `Swift/ScanGuidanceRenderPipeline.swift` | `App/ScanGuidance/ScanGuidanceRenderPipeline.swift` |
| `Swift/WedgeGeometryGenerator.swift` | `Core/Quality/Geometry/WedgeGeometryGenerator.swift` |
| `Swift/FlipAnimationController.swift` | `Core/Quality/Animation/FlipAnimationController.swift` |
| `Swift/RipplePropagationEngine.swift` | `Core/Quality/Animation/RipplePropagationEngine.swift` |
| `Swift/SpatialHashAdjacency.swift` | `Core/Quality/Geometry/SpatialHashAdjacency.swift` |
| `Swift/GrayscaleMapper.swift` | `App/ScanGuidance/GrayscaleMapper.swift` |
| `Swift/ScanGuidanceVertexDescriptor.swift` | `App/ScanGuidance/ScanGuidanceVertexDescriptor.swift` |
| `Swift/ScanGuidanceConstants.swift` | `Core/Constants/ScanGuidanceConstants.swift` |

### Metal Shaders
| Archive Path | Original Path |
|-------------|--------------|
| `Metal/ScanGuidance.metal` | `App/ScanGuidance/Shaders/ScanGuidance.metal` |

### Tests
All from `Tests/ScanGuidanceTests/`

### ScanViewModel Snapshot
| Archive Path | Original Path |
|-------------|--------------|
| `ScanViewModel_original.swift` | `App/Scan/ScanViewModel.swift` (before modification) |

## How to Restore

1. Copy files from archive back to original paths (see table above)
2. Restore `Package.swift` source file entries
3. Restore `ScanViewModel.swift` from `ScanViewModel_original.swift`
4. Rebuild

## Note

The C++ wedge geometry code (`aether_cpp/src/render/wedge_geometry.cpp`) was NOT archived
because it was NOT removed from the project. It remains in the C++ core layer.
