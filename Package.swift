// swift-tools-version: 6.2
import PackageDescription

// mlx-image-runtime: the engine half of ML[X] Image Server, as a package of its own. It turns image requests into
// model runs on MLXEngine and ForgeCore: the model catalog, routing, the runner, request mapping, and the wire types
// they share.
//
//   ImageServerAPI      wire types and seam protocols (jobs, models, licences, assets). MLXToolKit only, no MLX.
//   ImageServerModels   the runtime: CatalogEntry, ForgeCore's processing tiers (ModelCatalog.processing()), the
//                       engine service and router, the runner over MLXServeEngine, request mapping. Links ForgeCore
//                       and no generative package.
//   ImageServerCatalog  the generative and analysis packages (ModelCatalog.all/generative/analysis): Z-Image, Klein,
//                       Qwen-Image Edit and Flash, Mage-Flow, SenseNova U1, Ming, Boogu, Anima, Qwen-Image 2.1,
//                       Mage-VL. Linking it links all of them.
//
// Used by ML[X] Image Server and by the Pixel Agency Image Engine (whose normalizer needs only ImageServerModels, so
// an app can embed ForgeCore's tiers without the generative packages).
let package = Package(
    name: "mlx-image-runtime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ImageServerAPI", targets: ["ImageServerAPI"]),
        .library(name: "ImageServerModels", targets: ["ImageServerModels"]),
        .library(name: "ImageServerCatalog", targets: ["ImageServerCatalog"]),
    ],
    dependencies: [
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.66.0"),
        // ≥ 0.35.0: EngineImageCoding.rawImage(from:keepingDepth:), so an enhancer result keeps a 16-bit request's depth.
        .package(url: "https://github.com/xocialize/ForgeCore.git", from: "0.35.0"),
        // The enhancer seam's types (UpscaleTier, UpscaleFactor) for ×6/×8 chains and the generative tiers.
        .package(url: "https://github.com/xocialize/ForgeOptimizerKit.git", from: "0.23.0"),
        // Generative packages, registered as ForgeCore `ExternalRegistration`s.
        // ≥ 0.5.3: its int8/int4 tiers download the published bf16 snapshot (AB-T-0221).
        // z-image ≥ 0.5.4, klein ≥ 0.8.1, qwen-image-edit ≥ 0.9.3 report RunProgress phases and
        // denoise steps, so running jobs show step progress (AB-A-0139).
        .package(url: "https://github.com/xocialize/z-image-swift.git", from: "0.5.4"),
        .package(url: "https://github.com/xocialize/flux2-klein-swift.git", from: "0.8.1"),
        .package(url: "https://github.com/xocialize/qwen-image-edit-swift.git", from: "0.9.3"),
        // Mage-Flow (MIT weights and port): prod since runtime 0.3.0. ≥ 0.11.0: the edit's `tiles` mode and the
        // small-Mac residency (conditioner and DiT take turns).
        .package(url: "https://github.com/xocialize/mage-flow-swift.git", from: "0.11.0"),
        // Work in progress: registered as maturity .wip (named use only, never default-routed).
        .package(url: "https://github.com/xocialize/sensenova-u1-swift.git", from: "0.5.1"),
        .package(url: "https://github.com/xocialize/ming-image-swift.git", from: "0.3.0"),
        .package(url: "https://github.com/xocialize/boogu-image-swift.git", from: "0.4.0"),
        // CircleStone non-commercial weights (evaluation): registered only when a local snapshot is configured.
        .package(url: "https://github.com/xocialize/anima-mlx-swift.git", from: "0.3.0"),
        // Qwen Research licence (non-commercial): research tier, stamped restricted. ≥ 0.2.0 for the Turbo checkpoint.
        .package(url: "https://github.com/xocialize/qwen-image21-swift.git", from: "0.2.0"),
        // Mage-VL (Apache-2.0): imageAnalysis, for captions, alt text and tags.
        .package(url: "https://github.com/xocialize/mage-vl-swift.git", from: "0.4.0"),
    ],
    targets: [
        .target(name: "ImageServerAPI", dependencies: [
            .product(name: "MLXToolKit", package: "mlx-engine-swift"),
        ]),
        .target(name: "ImageServerModels", dependencies: [
            "ImageServerAPI",
            .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            // The hub listing's error type, to name the repo a download failed on.
            .product(name: "MLXHubMetadata", package: "mlx-engine-swift"),
            .product(name: "ForgeCore", package: "ForgeCore"),
            .product(name: "ForgeOptimizerKit", package: "ForgeOptimizerKit"),
        ]),
        .target(name: "ImageServerCatalog", dependencies: [
            "ImageServerAPI",
            "ImageServerModels",
            .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            .product(name: "ForgeCore", package: "ForgeCore"),
            .product(name: "MLXZImage", package: "z-image-swift"),
            .product(name: "MLXKlein", package: "flux2-klein-swift"),
            .product(name: "MLXQwenImageFlash", package: "qwen-image-edit-swift"),
            .product(name: "MLXQwenImageEdit", package: "qwen-image-edit-swift"),
            .product(name: "MLXMageFlow", package: "mage-flow-swift"),
            .product(name: "MLXSenseNovaU1", package: "sensenova-u1-swift"),
            .product(name: "MLXMingImage", package: "ming-image-swift"),
            .product(name: "MLXBoogu", package: "boogu-image-swift"),
            .product(name: "MLXAnima", package: "anima-mlx-swift"),
            .product(name: "MLXQwenImage21", package: "qwen-image21-swift"),
            .product(name: "MLXMageVL", package: "mage-vl-swift"),
        ]),
        .testTarget(name: "ImageRuntimeTests", dependencies: [
            "ImageServerAPI", "ImageServerModels", "ImageServerCatalog",
            .product(name: "MLXHubMetadata", package: "mlx-engine-swift"),
            .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            .product(name: "MLXMageFlow", package: "mage-flow-swift"),
        ]),
    ]
)
