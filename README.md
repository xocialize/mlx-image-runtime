# mlx-image-runtime

The engine half of ML[X] Image Server, as its own package. It turns image requests into model runs on
[MLXEngine](https://github.com/xocialize/mlx-engine-swift) and [ForgeCore](https://github.com/xocialize/ForgeCore):
the model catalog, routing and licence classification, the runner, request mapping, and the wire types they share.

It has no HTTP server and no library. ML[X] Image Server puts its REST/MCP surface and asset library on top of it, and
the [Pixel Agency Image Engine](https://github.com/xocialize/pixel-agency-image-engine) puts a
[Media Engine Specification](https://github.com/xocialize/media-engine-spec) engine on top of it.

Apple silicon, macOS 26, Swift 6.2.

## Products

| Product | What it is | Links |
|---|---|---|
| `ImageServerAPI` | Wire types and seam protocols: jobs, models, licence stamps, assets. No MLX. | MLXToolKit |
| `ImageServerModels` | The runtime: `CatalogEntry`, ForgeCore's image-processing tiers (`ModelCatalog.processing()`), `ImageEngineService`, routing, `ModelRunner`, request mapping and submit validation. | ForgeCore, no generative package |
| `ImageServerCatalog` | The generative and analysis packages: `ModelCatalog.all()`, `generative()`, `analysis()`. | every package below |

Upscales take `scale` 2, 4, 6 or 8. An `EngineRunner` given ForgeCore's `EngineImageEnhancer` serves ×6 and ×8 as
chains (the model at ×4, then NERVE ×2, then a fit down for ×6) and runs the generative tiers (VOSR2, Nacre) behind
the text-legibility guard; the result is `RunOutput.upscaled(image, model:)`, naming what ran. Without the enhancer,
every upscale is the model's own single pass at ×2 or ×4.

`anime4k-upscale` (Anime4K VL, 0.6.0) is the Instant tier: ForgeCore's weightless registration (Metal shaders, MIT,
nothing to download). It serves ×2 and ×4 itself; with the enhancer, ×6 and ×8 run as its own doublings (×6 fitted
from ×8), named so in `RunOutput.upscaled`. Offered by name, never a default route.

Take `ImageServerModels` alone to embed ForgeCore's tiers (upscale, restore, colorize, inpaint, matte, segment,
quality scoring) without the generative packages. Add `ImageServerCatalog` for generation and editing.

```swift
.package(url: "https://github.com/xocialize/mlx-image-runtime.git", from: "0.8.0"),
```

## The catalog

`ModelCatalog.all()` is the generative packages, then Mage-VL, then ForgeCore's tiers. Each entry carries its public
id, the engine package id it registers under, its capabilities, maturity (`prod` or `wip`), its measured size
envelope and its licence.

| Maturity | Models |
|---|---|
| `prod` | Z-Image and Z-Image Turbo, FLUX.2 Klein 4B and Klein 4B Base, Qwen-Image Flash, Qwen-Image-Edit 2511, Mage-Flow (and Turbo; Edit, Edit Turbo and Edit Base), MOSS-Image (SFT and Base), Mage-VL, ForgeCore's tiers |
| `wip` | SenseNova U1.5, Ming-Image, Boogu, Anima, Qwen-Image 2.1 (Turbo and Base) |

Default routing picks only `prod` models with permissive licences. Everything else runs only when a request names it.

Licence classes come from each package's own declaration, classified against the engine's allowlists
(`LicenseClassifier`): `permissive`, `evalAcknowledged` (for example Anima's CircleStone non-commercial weights) or
`restricted` (for example Qwen-Image 2.1's Qwen Research licence). A derived asset inherits the most restrictive class
of its model and inputs.

## Weights

Most packages download their weights through the engine's model store. A few read local snapshots: Boogu and Anima
register only when theirs is found, and Qwen-Image 2.1 needs its Turbo, base and Qwen3-VL-8B snapshots to run. The
runtime finds them through:

- `MLXIMG_WEIGHTS_ROOT`: a folder holding snapshots by their usual folder names.
- `MLXIMG_SNAPSHOT_<ID>`: one model's snapshot, for example `MLXIMG_SNAPSHOT_QWEN_IMAGE_2_1_TURBO`.

Mage-Flow's content filter (Microsoft's Responsible-AI screen) is off by default: it refused benign photos and is the
slowest stage of a 4-step edit. Set `MLXIMG_MAGE_CONTENT_FILTER=1` to turn it on; a refusal then fails the job with the
filter's verdict.

### MOSS-Image

`moss-image-sft` (MOSS-Image) and `moss-image-base` (0.7.0, moss-image-swift ≥ 0.2.0) are prod and permissive, preferred
for nothing. SFT renders long English and Chinese text and takes JSON layout prompts that place text and objects by
bounding box; Base is the checkpoint it was tuned from. 50 steps with CFG 3, about 2 minutes per 1024² image on an M5
Max, sides multiples of 16 from 256² to 1456² by area. Both download from the mlx-community mirrors, and share the SFT
mirror's 16.8 GB text encoder and VAE.

The DiT tier (`ModelCatalog.mossQuant`) and the Qwen3.5-9B encoder tier (`ModelCatalog.mossTextEncoderQuant`,
moss-image-swift ≥ 0.2.0) follow the Mac (AB-D-0152). In-app peaks (phys_footprint):

| Mac | DiT | Encoder | Resident between jobs | Peak at 1024² | Peak at 1456² | Declared (0.11.0) |
|---|---|---|---|---|---|---|
| 48 GB or more | bf16 | bf16 | 10.4 GB | 26.5 GB (encode) | 26.5 GB (encode) | 10.5 + 16.7 = 27.2 GB |
| below 48 GB | int8 | int8 | 5.8 GB | 15.7 GB (encode) | 15.7 GB (encode) | 5.8 + 10.4 = 16.2 GB |

0.11.0 needs moss-image-swift ≥ 0.3.0, which decodes the VAE in row bands (flux2-vae-mlx-swift ≥ 0.6.0): the same
image (124 dB vs untiled in fp32, no seams), and the 1456² decode no longer sets the peak. The per-request encode is
the peak at every size, so the encoder tier sets the activation: 16.7 GB with the bf16 encoder, 10.4 GB with the int8
one. That takes int8/int8 from 23.3 to 16.2 GB declared, inside a 24 GB Mac's budget. 0.10.1 (moss-image-swift
0.2.1) declared 17.5 GB on every lane for the untiled decode (AB-T-0317, AB-R-0575).

Text error is within noise of bf16/bf16 on both lanes (an OCR gate over 20 EN/ZH long-text prompts, AB-R-0572).
`MLXIMG_MOSS_QUANT` overrides the DiT tier and `MLXIMG_MOSS_TE_QUANT` the encoder tier, each `bf16` or `int8`.

### FLUX 3 Klein (restricted)

`flux-3-klein` (0.9.0; 0.10.0 needs flux3-klein-swift ≥ 0.3.0) is FLUX 3 Image Klein from Black Forest Labs: text-to-image and
editing with up to 10 reference images in one model, 16 steps, strong English text, bounding-box layout in the prompt.
It needs **full scene captions**; a short prompt gives generic output.

- **Licence:** the FLUX Kommunity License, so the entry stamps **restricted**, is `wip` and preferred for nothing. A
  host offers it by name only, for example behind Pixel Agency Image Engine's `--allow-research` (AB-D-0151).
  - Non-commercial use is allowed.
  - Commercial use of outputs is allowed only for businesses under US$5M revenue that filter content and disclose AI
    generation.
  - Outputs must never train a similar model.
- **Weights:** they download from the **gated** mlx-community mirror. The account behind the HF token must have accepted
  the licence on Hugging Face. `MLXIMG_WEIGHTS_ROOT/flux-3-image-klein` (BFL's bf16 package) is read in place.
- **Envelope (0.10.0):** output up to 2048² area, sides multiples of 16. A single reference is fitted to 1664² (2.77 MP);
  its VAE encode is still untiled. Before: 1152².

The DiT tier follows the Mac (`ModelCatalog.flux3Quant`). Every tier's text is within the pre-registered OCR tolerance
of bf16 (AB-R-0576). Footprints are from flux3-klein-swift 0.3.0, whose VAE decodes in row bands (AB-R-0579).

| Mac | DiT | Declared resident + activation | phys peak, worst request in the envelope |
|---|---|---|---|
| 48 GB or more | bf16 | 11.7 + 12.0 GB | 24.5 GB (1664² reference), 22.8 GB (10 refs → 2048²) |
| 32–48 GB | int8 | 6.7 + 12.0 GB | not measured (MLX 17.8 GB) |
| below 32 GB | int4, 8-bit attention | 4.9 + 12.0 GB | 17.8 GB |

- A 24 GB Mac (19.07 GB budget) now admits int4: 16.9 GB declared, against 20.4 GB before 0.10.0.
- int4 renders a different image from bf16 at the same seed.
- `MLXIMG_FLUX3_QUANT` (`bf16`, `int8`, `int4`) overrides the tier.


**Prompt upsampler (0.12.0, flux3-klein-swift ≥ 0.5.0).**
- **What it does:** each request first goes through BFL's Apache-2.0 prompt upsampler, which expands a short request
  into the full scene caption the model needs. It adds about 10 s per request.
- **Tier:** int8 on every Mac. Its 11.1 GB transient stays under the declared activation, so the ladder above is
  unchanged. `ModelCatalog.flux3Upsampler`; `MLXIMG_FLUX3_UPSAMPLER` (`off`, `bf16`, `int8`, `int4`) overrides it.
- **Weights:** from the mlx-community mirror (`flux-3-image-klein-pup-8bit`, public), or read in place from
  `MLXIMG_WEIGHTS_ROOT/flux-3-image-klein-pup-8bit` (`flux-3-image-klein-pup` for bf16).
- **Skipping it:** a caller that wrote its own caption sends `metaData["upsample"] = false`.

### Mage-Flow-Edit on small Macs

Mage-Flow-Edit holds two big models: the Qwen3-VL conditioner (8.3 GB) and the DiT (5.6 GB at int8). How they stay in
memory follows the Mac (`ModelCatalog.mageResidency`):

| Mac | Residency | Peak (int8 Turbo, 1024²) |
|---|---|---|
| 32 GB or more | `resident`: both stay loaded | about 17 GB |
| below 32 GB | `evict-all`: the conditioner and the DiT take turns, and neither stays between requests | about 10 GB |

`MLXIMG_MAGE_RESIDENCY` (`resident`, `evict-conditioner`, `evict-all`) overrides it. Taking turns costs one load of each
model per request, so a job that edits many images at once sends them in one request with the package's `tiles` mode
(mage-flow-swift ≥ 0.11.0; `RequestMapping` passes `mode`, the images, the tile side, the base seed and `initSigma`
through unchanged). The Pixel Agency Image Engine's creative upscale does this.

`EngineRunner.machineFit` also reports the engine's projected peak for a model and the engine's memory budget on this
Mac (`MemoryFit.projectedPeakBytes`, `budgetBytes`, `fitsBudget`), so a host can tell "doesn't fit right now" from
"never fits this Mac".

`ImageEngineService.downloadCheck(_:)` says what a model's first use would download, without downloading: each
missing weight source listed and sized on the hub (`.pending`), nothing to fetch (`.present`), or a package that
fetches its own weights where the engine can't see them (`.opaque`; none in the catalog since AB-T-0222). When a download
fails, `EngineRunner.prepare` throws `WeightDownloadError`, which names the repos and what the hub said; the engine's
own error was a bare `httpStatus(404)` (AB-T-0221).

## Build and test

```bash
swift build
```

```bash
swift test
```

The tests check the catalog, licence inheritance and seed bounds without loading a model. With network access they
also list every prod model's first download on the hub from an empty models folder (skipped offline). End-to-end coverage lives
with the users: ML[X] Image Server's test suite and the Image Engine's live conformance runs.

## Licence

MIT. Each model package and its weights keep their own licences; the catalog states them on every entry.
