# Phase 6.5 — MetalSplatter cross-validation fork setup

This is a **manual-step playbook** the user runs once to set up the
MetalSplatter fork that serves as the cross-validation oracle for
Phase 6.5. Claude Code can't fork to the user's GitHub on their behalf;
this doc captures everything needed so the setup is reproducible.

## Why we fork (vs use upstream as-is)

Upstream MetalSplatter at https://github.com/scier/MetalSplatter is
shipped in the App Store (Vision Pro viewer + OverSoul social app), so
its rendering math is production-validated by Apple's review process.
**The math is the oracle**.

But its UI doesn't natively dump raw RGBA frames — Phase 6.5 needs
ULP-level pixel diff (≤2/255 max abs across 100% of pixels), and PNG
screenshots have lossy compression that exceeds that budget. We add a
debug-build-only IOSurface raw RGBA dump path; production App Store
build is unaffected.

## Step 1 — fork to user's GitHub

Manual via GitHub UI:

1. Visit https://github.com/scier/MetalSplatter
2. Click "Fork" → fork to user's account (Kyle-Wang0211)
3. Resulting URL: `https://github.com/Kyle-Wang0211/MetalSplatter`
4. Pin the upstream commit being forked (capture the SHA from the
   fork's default branch HEAD at fork time):

```bash
gh api repos/Kyle-Wang0211/MetalSplatter/commits/main --jq '.sha' > /tmp/metalsplatter_pin.txt
cat /tmp/metalsplatter_pin.txt
```

Update `CROSS_PLATFORM_STACK.md` MetalSplatter row with that hash.

## Step 2 — clone fork locally

Outside the Aether3D-cross repo (MetalSplatter is NOT vendored — it's
a separate sibling project used only for cross-val):

```bash
cd ~/Documents
git clone https://github.com/Kyle-Wang0211/MetalSplatter.git
cd MetalSplatter
git checkout -b phase6-iosurface-dump
```

## Step 3 — add IOSurface raw RGBA dump path

Patch the iOS app target to:

1. Render to an IOSurface-backed `MTLTexture` (instead of the existing
   drawable-only path) when a `kAetherDumpEnvVar` env var is set
2. After each frame render, copy the IOSurface bytes to a file
   `~/Documents/aether_dump_<timestamp>_<frame>.rgba`
3. The file format is raw RGBA8, width and height encoded in the
   filename: `aether_dump_<frame>_<W>x<H>.rgba`

Approximate budget: 50–80 lines of Swift. Reuses the Phase 4 IOSurface
plumbing pattern from `pocketworld_flutter/macos/Runner/MainFlutterWindow.swift`
+ `pocketworld_flutter/ios/Runner/MetalRenderer.swift`.

Implementation outline:

```swift
// In MetalSplatter's view controller:
import IOSurface

private var dumpEnabled: Bool {
    ProcessInfo.processInfo.environment["AETHER_DUMP"] != nil
}

private func dumpIfEnabled(texture: MTLTexture, frame: Int) {
    guard dumpEnabled else { return }
    let bytesPerRow = texture.width * 4  // RGBA8
    let totalBytes = bytesPerRow * texture.height
    var data = Data(count: totalBytes)
    data.withUnsafeMutableBytes { ptr in
        texture.getBytes(
            ptr.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
    }
    let docs = FileManager.default.urls(for: .documentDirectory,
                                          in: .userDomainMask)[0]
    let url = docs.appendingPathComponent(
        "aether_dump_\(frame)_\(texture.width)x\(texture.height).rgba")
    try? data.write(to: url)
}
```

Note: the user's plan tradeoff was option 1 (UI button → texture.getBytes())
vs option 3 (IOSurface route). Above is option 1 (`texture.getBytes`)
because it's simpler. Option 3 (IOSurface) is the alternative if a
zero-copy dump is needed for very high-resolution scenes; for the 20
test pairs at standard resolution, `getBytes` is fine.

## Step 4 — build forked MetalSplatter for iPhone 14 Pro

Standard Xcode workflow (same identity / team as PocketWorld):

```bash
cd ~/Documents/MetalSplatter
xcodebuild -project MetalSplatter.xcodeproj \
    -scheme "MetalSplatter iOS" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates
# Re-sign frameworks per scripts/deploy_iphone.sh pattern
# Install via xcrun devicectl device install app
```

## Step 5 — capture cross-validation dumps

For each (scene, camera) pair (20 total per Phase 6.5 plan):

```bash
# 1. Set env var for dump path
xcrun devicectl device process launch \
    --device 00008120-00146C4A1AEBC01E \
    --environment-variables AETHER_DUMP=1 \
    com.kyle.MetalSplatter

# 2. Drive UI to load the .ply / .splat scene + position camera
#    Manual or via UIAutomation script

# 3. After each frame renders, .rgba files appear in MetalSplatter's
#    Documents directory. Pull via:
xcrun devicectl device copy from-device \
    --device 00008120-00146C4A1AEBC01E \
    --domain document-data \
    --bundle-id com.kyle.MetalSplatter \
    --source 'aether_dump_*.rgba' \
    --destination ~/Documents/Aether3D-cross/aether_cpp/test_data/cross_val/metalsplatter/
```

Then run `scripts/cross_validate_vs_metalsplatter.py` (Phase 6.5 work,
not yet written) to diff against PocketWorld's dumps.

## License attribution

MetalSplatter is MIT-licensed. If we vendor any code from MetalSplatter
into Aether3D-cross (we currently DO NOT — only the fork is used),
add a `LICENSE-MetalSplatter` file at repo root.

## Time budget

Steps 1-2: ~5 minutes (manual GitHub fork + clone)
Step 3: ~2-4 hours (Swift code + iOS build + first-time provisioning)
Step 4: ~30 minutes
Step 5: ~30 minutes per (scene, camera) pair × 20 pairs = ~10 hours total
        (includes manual camera driving — automate via UIAutomation if rerunning)

## Trigger to do

Phase 6.5 (cross-validation execution). Don't do this earlier — Phase 6.0–6.4
work doesn't need the fork. When Phase 6.4 is done and 6.5 starts, this is the
first step.
