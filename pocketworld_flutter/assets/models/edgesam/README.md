# MobileSAM ONNX models

Pre-exported ONNX weights for on-device subject masking during capture.
Used by `lib/capture/sam/mobile_sam_inference.dart` and consumed by
the worker-side `apply_subject_mask` stage via the `subject_mask` field
in `curated.json`.

## Files

| File                              | Size    | Role                                          |
|-----------------------------------|---------|-----------------------------------------------|
| `mobile_sam_image_encoder.onnx`   | 28.2 MB | TinyViT image encoder (1024x1024 → embedding) |
| `sam_mask_decoder_single.onnx`    | 16.5 MB | SAM mask decoder (point prompt → mask)        |

Total on-device footprint: ~44.7 MB.

## Source

- Repo: https://huggingface.co/Acly/MobileSAM
- Commit SHA: `0d3b403339b4674a82493d5e97964dd78089ddc8`
- Date downloaded: 2026-05-11

## Upstream

- Paper / project: https://github.com/ChaoningZhang/MobileSAM
- Original weights: ChaoningZhang/MobileSAM (Apache-2.0)
- ONNX export: pre-exported by the Acly/MobileSAM HF mirror so we don't
  have to ship the PyTorch toolchain on the build machine.

## License

**Apache-2.0** — commercial-use friendly. See
https://github.com/ChaoningZhang/MobileSAM/blob/master/LICENSE.

We deliberately did NOT pick EdgeSAM (S-Lab License 1.0,
non-commercial-only) for this reason. The directory name `edgesam/` is
a forward-compat artifact from an earlier session — contents are
MobileSAM.

## Why these two files specifically

MobileSAM's inference is two ONNX sessions:
1. **Encoder** runs once per frame (the heavy part), produces an image
   embedding tensor.
2. **Decoder** runs once per prompt point (cheap), takes the embedding
   plus prompt coords and outputs a low-res (256x256) mask logit map.

The capture pipeline always prompts the dead-center of the frame
(W/2, H/2) because the dome guidance keeps the subject there. Both
files are loaded once at session warm-up; the encoder is the >80% of
inference latency.

## LFS

Tracked as Git LFS pointers via `.gitattributes` (`*.onnx filter=lfs`).
Cloning fresh requires `git lfs install` then `git lfs pull` to
hydrate the actual model bytes.
