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
.package(url: "https://github.com/xocialize/mlx-image-runtime.git", from: "0.5.0"),
```

## The catalog

`ModelCatalog.all()` is the generative packages, then Mage-VL, then ForgeCore's tiers. Each entry carries its public
id, the engine package id it registers under, its capabilities, maturity (`prod` or `wip`), its measured size
envelope and its licence.

| Maturity | Models |
|---|---|
| `prod` | Z-Image and Z-Image Turbo, FLUX.2 Klein 4B and Klein 4B Base, Qwen-Image Flash, Qwen-Image-Edit 2511, Mage-Flow (and Turbo; Edit, Edit Turbo and Edit Base), Mage-VL, ForgeCore's tiers |
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
