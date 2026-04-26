// Phase 6.3 — vendor-time WGSL preprocessor (Path G).
//
// Resolves Brush's #import + #ifdef directives into standard WGSL via
// naga_oil (the same preprocessor Brush uses internally for its own
// WGSL→Tint pipeline). Output is plain WGSL that Tint/Dawn can compile
// directly, no runtime-side preprocessor required.
//
// Input:  aether_cpp/shaders/wgsl/_brush_raw/*.wgsl  (vendored unmodified)
// Output: aether_cpp/shaders/wgsl/*.wgsl              (preprocessed, committed)
//
// Run from repo root:
//
//     cd aether_cpp/scripts/wgsl_preprocess
//     cargo run --release
//
// Per-kernel `shader_defs` are derived from each file's leading
// `#define X` lines (Brush's convention for "this kernel needs flag X").
// helpers.wgsl reacts to those via `#ifdef X`. naga_oil applies them
// when calling `make_naga_module` per kernel.

use anyhow::{Context, Result, anyhow};
use naga_oil::compose::{
    ComposableModuleDescriptor, Composer, NagaModuleDescriptor, ShaderDefValue,
};
use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

// Top-level kernels that should be emitted as standalone WGSL files.
// `imports` lists the helper modules each kernel needs registered first.
// Each import is (filename-in-_brush_raw, name-as-used-in-#import-directive).
//
// Why both: we renamed Brush's `sorting.wgsl` to `sort_sorting.wgsl` during
// vendor (to namespace it alongside other crate helpers like
// `prefix_sum_helpers.wgsl`), but kernels still reference it as
// `#import sorting` because we don't edit the raw files. So filename and
// import-name diverge for that one case; keeping the mapping explicit
// avoids per-kernel hacks.
struct Kernel {
    raw_filename: &'static str,
    out_filename: &'static str,
    imports: &'static [(&'static str, &'static str)],
}

const KERNELS: &[Kernel] = &[
    // ─── viewer (brush-render) — kernels use `#import helpers` ───
    Kernel {
        raw_filename: "project_forward.wgsl",
        out_filename: "project_forward.wgsl",
        imports: &[("helpers.wgsl", "helpers")],
    },
    Kernel {
        raw_filename: "project_visible.wgsl",
        out_filename: "project_visible.wgsl",
        imports: &[("helpers.wgsl", "helpers")],
    },
    Kernel {
        raw_filename: "map_gaussian_to_intersects.wgsl",
        out_filename: "map_gaussian_to_intersects.wgsl",
        imports: &[("helpers.wgsl", "helpers")],
    },
    Kernel {
        raw_filename: "rasterize.wgsl",
        out_filename: "rasterize.wgsl",
        imports: &[("helpers.wgsl", "helpers")],
    },
    // ─── training backward (brush-render-bwd) — also `#import helpers` ───
    Kernel {
        raw_filename: "project_backwards.wgsl",
        out_filename: "project_backwards.wgsl",
        imports: &[("helpers.wgsl", "helpers")],
    },
    Kernel {
        raw_filename: "rasterize_backwards.wgsl",
        out_filename: "rasterize_backwards.wgsl",
        imports: &[("helpers.wgsl", "helpers")],
    },
    // ─── radix sort (brush-sort) — kernels use `#import sorting` ───
    // We renamed the file to sort_sorting.wgsl during vendor; register
    // it in naga_oil under the original name "sorting" so kernel imports
    // resolve.
    Kernel {
        raw_filename: "sort_count.wgsl",
        out_filename: "sort_count.wgsl",
        imports: &[("sort_sorting.wgsl", "sorting")],
    },
    Kernel {
        raw_filename: "sort_reduce.wgsl",
        out_filename: "sort_reduce.wgsl",
        imports: &[("sort_sorting.wgsl", "sorting")],
    },
    Kernel {
        raw_filename: "sort_scan.wgsl",
        out_filename: "sort_scan.wgsl",
        imports: &[("sort_sorting.wgsl", "sorting")],
    },
    Kernel {
        raw_filename: "sort_scan_add.wgsl",
        out_filename: "sort_scan_add.wgsl",
        imports: &[("sort_sorting.wgsl", "sorting")],
    },
    Kernel {
        raw_filename: "sort_scatter.wgsl",
        out_filename: "sort_scatter.wgsl",
        imports: &[("sort_sorting.wgsl", "sorting")],
    },
    // ─── prefix sum (brush-prefix-sum) — kernels use `#import prefix_sum_helpers` ───
    Kernel {
        raw_filename: "prefix_sum_scan.wgsl",
        out_filename: "prefix_sum_scan.wgsl",
        imports: &[("prefix_sum_helpers.wgsl", "prefix_sum_helpers")],
    },
    Kernel {
        raw_filename: "prefix_sum_scan_sums.wgsl",
        out_filename: "prefix_sum_scan_sums.wgsl",
        imports: &[("prefix_sum_helpers.wgsl", "prefix_sum_helpers")],
    },
    Kernel {
        raw_filename: "prefix_sum_add_scanned_sums.wgsl",
        out_filename: "prefix_sum_add_scanned_sums.wgsl",
        imports: &[("prefix_sum_helpers.wgsl", "prefix_sum_helpers")],
    },
];

/// Files that are imports-only (helpers), never emitted as standalone WGSL.
const HELPERS_ONLY: &[&str] = &[
    "helpers.wgsl",
    "sort_sorting.wgsl",
    "prefix_sum_helpers.wgsl",
];

/// Parse leading `#define X` lines from a WGSL file. Brush's convention:
/// each kernel may set a few flags at the top to alter helpers' #ifdef
/// branches. Returns a HashMap suitable for `NagaModuleDescriptor.shader_defs`.
fn parse_shader_defs(source: &str) -> HashMap<String, ShaderDefValue> {
    let mut defs = HashMap::new();
    for line in source.lines() {
        let line = line.trim();
        if !line.starts_with("#define ") {
            // Stop at first non-define / non-comment / non-blank line.
            // Comments + blank lines tolerated; everything else ends the
            // header.
            if line.is_empty() || line.starts_with("//") {
                continue;
            }
            break;
        }
        let rest = line.trim_start_matches("#define ").trim();
        // Brush only uses bare `#define FLAG` (no value), translating to
        // ShaderDefValue::Bool(true).
        let name = rest.split_whitespace().next().unwrap_or("");
        if !name.is_empty() {
            defs.insert(name.to_owned(), ShaderDefValue::Bool(true));
        }
    }
    defs
}

/// Strip naga_oil's name-mangling suffix from output WGSL.
///
/// naga_oil's Composer marks types/functions imported from a module with
/// `<original_name>X_naga_oil_mod_X<BASE32_ENCODED_MODULE_NAME>X` so the
/// composed naga::Module avoids name collisions across modules. After
/// composition + writing back to WGSL, those mangled names appear in the
/// output — they're valid WGSL but ugly to read and pointlessly long.
///
/// Strip the entire mangling suffix so types/functions have their plain
/// original names. Brush's own brush-wgsl crate does an equivalent
/// demangle for its Rust codegen (see crates/brush-wgsl/src/lib.rs
/// `demangle_str`); we do the simpler "just drop the suffix" because we
/// emit raw WGSL not Rust paths.
fn naga_oil_mangle_regex() -> &'static Regex {
    static MEM: OnceLock<Regex> = OnceLock::new();
    MEM.get_or_init(|| {
        Regex::new(r"X_naga_oil_mod_X[A-Z0-9]*X").unwrap()
    })
}

fn demangle_naga_oil(s: &str) -> String {
    naga_oil_mangle_regex().replace_all(s, "").into_owned()
}

/// Strip our 9-line attribution header from a raw vendored file before
/// feeding it to naga_oil. naga_oil treats `//`-comments as opaque source
/// and would copy them through; better to strip + re-attach below the
/// preprocessed output.
fn strip_attribution_header(source: &str) -> (&str, String) {
    let attribution_end = "for upstream re-pin reproducibility.";
    if let Some(idx) = source.find(attribution_end) {
        // Find the line break after the marker line.
        let after = &source[idx + attribution_end.len()..];
        let nl = after.find('\n').unwrap_or(0) + idx + attribution_end.len() + 1;
        let header = source[..nl].to_owned();
        let body = &source[nl..];
        (body, header)
    } else {
        // No header found — return source unmodified.
        (source, String::new())
    }
}

fn main() -> Result<()> {
    // Resolve paths relative to this Cargo crate's location:
    //   <repo>/aether_cpp/scripts/wgsl_preprocess/
    // Raw input:  ../../../shaders/wgsl/_brush_raw/
    // Output:     ../../../shaders/wgsl/
    let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let raw_dir = crate_dir.join("../../shaders/wgsl/_brush_raw").canonicalize()
        .context("Cannot find aether_cpp/shaders/wgsl/_brush_raw — vendored Brush WGSL must exist before preprocessing")?;
    let out_dir = crate_dir.join("../../shaders/wgsl").canonicalize()?;
    println!("raw_dir: {}", raw_dir.display());
    println!("out_dir: {}", out_dir.display());

    let mut errors: Vec<String> = Vec::new();
    let mut wrote: Vec<String> = Vec::new();

    for kernel in KERNELS {
        match preprocess_one(&raw_dir, &out_dir, kernel) {
            Ok(out_path) => wrote.push(out_path),
            Err(e) => errors.push(format!("{}: {:#}", kernel.raw_filename, e)),
        }
    }

    println!("\n=== Wrote {} files ===", wrote.len());
    for f in &wrote {
        println!("  ✓ {}", f);
    }

    if !errors.is_empty() {
        println!("\n=== {} errors ===", errors.len());
        for e in &errors {
            println!("  ✗ {}", e);
        }
        return Err(anyhow!("{} kernel(s) failed preprocessing", errors.len()));
    }
    println!("\nAll {} top-level kernels preprocessed clean.", wrote.len());
    println!("Helpers-only modules (not emitted as standalone): {:?}", HELPERS_ONLY);
    Ok(())
}

fn preprocess_one(raw_dir: &Path, out_dir: &Path, kernel: &Kernel) -> Result<String> {
    // ─── 1. fresh composer per kernel (so #defines don't leak between kernels) ───
    let mut composer = Composer::default()
        .with_capabilities(naga::valid::Capabilities::all());

    // ─── 2. register imports (helpers) ───
    // Brush's helper files don't declare `#define_import_path`, so pass
    // the module name via `as_name` (matches Brush's brush-wgsl crate
    // pattern at crates/brush-wgsl/src/lib.rs).
    for (import_filename, import_name) in kernel.imports {
        let import_path = raw_dir.join(import_filename);
        let import_raw = fs::read_to_string(&import_path)
            .with_context(|| format!("read import {}", import_path.display()))?;
        let (import_body, _hdr) = strip_attribution_header(&import_raw);
        composer
            .add_composable_module(ComposableModuleDescriptor {
                source: import_body,
                file_path: import_filename,
                as_name: Some((*import_name).to_owned()),
                ..Default::default()
            })
            .map_err(|e| anyhow!("add_composable_module({}): {:?}", import_filename, e))?;
    }

    // ─── 3. read top-level kernel + parse its #defines ───
    let kernel_path = raw_dir.join(kernel.raw_filename);
    let kernel_raw = fs::read_to_string(&kernel_path)
        .with_context(|| format!("read kernel {}", kernel_path.display()))?;
    let (kernel_body, _hdr) = strip_attribution_header(&kernel_raw);
    let shader_defs = parse_shader_defs(kernel_body);

    // ─── 4. compose into a naga::Module ───
    let module = composer
        .make_naga_module(NagaModuleDescriptor {
            source: kernel_body,
            file_path: kernel.raw_filename,
            shader_defs,
            ..Default::default()
        })
        .map_err(|e| anyhow!("make_naga_module: {:?}", e))?;

    // ─── 5. validate, then write back as plain WGSL ───
    let info = naga::valid::Validator::new(
        naga::valid::ValidationFlags::empty(),
        naga::valid::Capabilities::all(),
    )
    .validate(&module)
    .map_err(|e| anyhow!("naga validate: {:?}", e))?;

    let raw_wgsl = naga::back::wgsl::write_string(
        &module,
        &info,
        naga::back::wgsl::WriterFlags::empty(),
    )
    .map_err(|e| anyhow!("naga::back::wgsl: {:?}", e))?;

    // Strip naga_oil's X_naga_oil_mod_X<base32>X mangling so type names
    // are readable. Doesn't change semantics — just shorter names.
    let wgsl = demangle_naga_oil(&raw_wgsl);

    // ─── 6. attach our adapted-attribution header + commit ───
    let final_output = format!(
        "// Adapted from Brush (https://github.com/ArthurBrussee/brush)\n\
         // Original: brush/{}\n\
         // Brush version: v0.3.0 (commit 3edecbb2fe79d3e2c87eeab85b15e0b1dd10d486)\n\
         // License: Apache-2.0 — see aether_cpp/third_party/brush/LICENSE\n\
         // Math source: gSplat reference kernels (3DGS paper, Kerbl et al. 2023)\n\
         //\n\
         // GENERATED by aether_cpp/scripts/wgsl_preprocess (Path G).\n\
         // Sources: aether_cpp/shaders/wgsl/_brush_raw/{}\n\
         // To regenerate: cd aether_cpp/scripts/wgsl_preprocess && cargo run --release\n\
         // DO NOT hand-edit this file — edits are clobbered on re-run.\n\
         //\n\n{}\n",
        find_original_path(kernel.raw_filename),
        kernel.raw_filename,
        wgsl
    );

    let out_path = out_dir.join(kernel.out_filename);
    fs::write(&out_path, &final_output)?;
    Ok(out_path.display().to_string())
}

/// Best-effort original Brush path lookup (for the attribution header).
fn find_original_path(raw_filename: &str) -> &'static str {
    match raw_filename {
        "helpers.wgsl"
        | "project_forward.wgsl"
        | "project_visible.wgsl"
        | "map_gaussian_to_intersects.wgsl"
        | "rasterize.wgsl" => "crates/brush-render/src/shaders/<file>",
        "project_backwards.wgsl"
        | "rasterize_backwards.wgsl" => "crates/brush-render-bwd/src/shaders/<file>",
        "sort_sorting.wgsl" => "crates/brush-sort/src/shaders/sorting.wgsl",
        "sort_count.wgsl"
        | "sort_reduce.wgsl"
        | "sort_scan.wgsl"
        | "sort_scan_add.wgsl"
        | "sort_scatter.wgsl" => "crates/brush-sort/src/shaders/<file>",
        "prefix_sum_helpers.wgsl"
        | "prefix_sum_scan.wgsl"
        | "prefix_sum_scan_sums.wgsl"
        | "prefix_sum_add_scanned_sums.wgsl" => "crates/brush-prefix-sum/src/shaders/<file>",
        _ => "<unknown>",
    }
}
