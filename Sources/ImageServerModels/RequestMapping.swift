import Foundation
import ImageServerAPI
import MLXToolKit

/// The capabilities this server serves, and which input slots each one takes.
public enum CapabilityShape {
    /// Generative capabilities produce `n` outputs from a prompt (and, for edits, reference images).
    public static let generative: Set<Capability> = [.textToImage, .imageEdit]

    /// Input slots per capability: name → (min, max). Edits take their max from the model's envelope.
    public static func inputSlots(_ capability: Capability) -> [(name: String, min: Int)] {
        switch capability {
        case .textToImage: []
        case .imageEdit: [("images", 1)]
        case .imageInpaint: [("image", 1), ("mask", 1)]
        case .imageUpscale, .imageRestore, .imageRelight, .imageColorize, .matting, .promptSegment,
             .imageQualityScore, .defectDetect, .imageAnalysis: [("image", 1)]
        default: []
        }
    }

    public static let served: Set<Capability> = [.textToImage, .imageEdit, .imageInpaint, .imageUpscale, .imageRestore,
                                          .imageRelight, .imageColorize, .matting, .promptSegment, .imageQualityScore,
                                          .defectDetect, .imageAnalysis]

    /// Canonical input names: `image`/`references`/`refs` all mean the edit's `images`; `source` means `image`.
    public static func canonicalInputs(_ inputs: [String: [AssetID]], for capability: Capability) -> [String: [AssetID]] {
        var out: [String: [AssetID]] = [:]
        for (name, ids) in inputs {
            let key: String
            switch (capability, name) {
            case (.imageEdit, "image"), (.imageEdit, "source"), (.imageEdit, "references"), (.imageEdit, "refs"),
                 (.imageEdit, "images"):
                key = "images"
            case (_, "source"), (_, "images"):   // every edit spelling is handled above
                key = "image"
            default:
                key = name
            }
            out[key, default: []] += ids
        }
        return out
    }
}

/// JobSpec (wire JSON) → typed engine request, and engine response → output. Validation that the caller can act on
/// happens at submit (`SubmitValidation`); this is the mechanical mapping for one output.
public enum RequestMapping {
    /// What a plain `imageAnalysis` call asks when the caller gives no prompt.
    public static let defaultAnalysisQuestion = "Describe this image in one or two sentences."

    public static func request(for work: RunWork) throws -> any CapabilityRequest {
        let spec = work.spec
        let mode = spec.mode.map { Mode(rawValue: $0) }
        func one(_ name: String) throws -> Image {
            guard let image = work.inputs[name]?.first else {
                throw JobError(code: "input_missing", message: "\(work.route.capability.rawValue) needs inputs.\(name).")
            }
            return image
        }
        switch work.route.capability {
        case .textToImage:
            let background = spec.effectiveParam("background")?.stringValue.flatMap(T2IBackground.init(rawValue:))
            return T2IRequest(
                prompt: spec.runPrompt,
                negativePrompt: spec.runNegativePrompt,
                width: work.width, height: work.height,
                steps: spec.effectiveParam("steps")?.intValue ?? work.route.defaults.steps,
                guidanceScale: guidance(spec) ?? work.route.defaults.guidance,
                seed: work.seed, background: background, mode: mode)
        case .imageEdit:
            var meta: MetaData = [:]
            if let strength = spec.effectiveParam("strength")?.doubleValue { meta["strength"] = .double(strength) }
            return IEditRequest(
                images: work.inputs["images"] ?? [], prompt: spec.runPrompt,
                negativePrompt: spec.runNegativePrompt, width: work.width, height: work.height,
                steps: spec.effectiveParam("steps")?.intValue ?? work.route.defaults.steps,
                guidanceScale: guidance(spec) ?? work.route.defaults.guidance, seed: work.seed, mode: mode,
                metaData: meta)
        case .imageUpscale:
            return ImageUpscaleRequest(image: try one("image"), scale: spec.effectiveParam("scale")?.intValue, mode: mode)
        case .imageRestore:
            return ImageRestoreRequest(image: try one("image"), strength: spec.effectiveParam("strength")?.doubleValue.map(Float.init),
                                       mode: mode)
        case .imageRelight:
            return ImageRelightRequest(image: try one("image"), strength: spec.effectiveParam("strength")?.doubleValue.map(Float.init),
                                       mode: mode)
        case .imageColorize:
            return ColorizeRequest(image: try one("image"), mode: mode)
        case .imageInpaint:
            return InpaintRequest(image: try one("image"), mask: try one("mask"), mode: mode)
        case .matting:
            let kind: Matte.Kind = spec.effectiveParam("kind")?.stringValue == "binary" ? .binary : .softAlpha
            return MattingRequest(image: try one("image"), preferredKind: kind, mode: mode)
        case .promptSegment:
            let points = spec.effectiveParam("points")?.arrayValue?.map { ($0.arrayValue ?? []).compactMap { $0.doubleValue.map(Float.init) } } ?? []
            let labels = spec.effectiveParam("pointLabels")?.arrayValue?.compactMap(\.intValue) ?? Array(repeating: 1, count: points.count)
            let box = spec.effectiveParam("box")?.arrayValue?.compactMap { $0.doubleValue.map(Float.init) }
            return PromptSegmentRequest(image: try one("image"), points: points, pointLabels: labels, box: box, mode: mode)
        case .imageQualityScore:
            return ImageQualityScoreRequest(image: try one("image"), mode: mode)
        case .imageAnalysis:
            return ImageAnalysisRequest(image: try one("image"),
                                        prompt: spec.effectiveParam("prompt")?.stringValue ?? RequestMapping.defaultAnalysisQuestion,
                                        mode: mode)
        case .defectDetect:
            let kind: Matte.Kind = spec.effectiveParam("kind")?.stringValue == "softAlpha" ? .softAlpha : .binary
            return DefectDetectRequest(image: try one("image"), preferredKind: kind,
                                       threshold: spec.effectiveParam("threshold")?.doubleValue.map(Float.init), mode: mode)
        default:
            throw JobError(code: "unsupported_capability", message: "\(work.route.capability.rawValue) is not served.")
        }
    }

    public static func output(from response: any CapabilityResponse) throws -> RunOutput {
        switch response {
        case let r as T2IResponse: return .image(r.image)
        case let r as IEditResponse: return .image(r.image)
        case let r as ImageUpscaleResponse: return .image(r.image)
        case let r as ImageRestoreResponse: return .image(r.image)
        case let r as ImageRelightResponse: return .image(r.image)
        case let r as ColorizeResponse: return .image(r.image)
        case let r as InpaintResponse: return .image(r.image)
        case let r as MattingResponse: return .matte(r.matte, score: nil)
        case let r as PromptSegmentResponse: return .matte(r.matte, score: r.score)
        case let r as DefectDetectResponse: return .matte(r.mask, score: nil)
        case let r as ImageQualityScoreResponse: return .score(r.score, subscores: r.subscores)
        case let r as ImageAnalysisResponse: return .text(r.text)
        default:
            throw JobError(code: "engine_error", message: "The engine returned \(type(of: response)), which this server does not store.")
        }
    }

    public static func guidance(_ spec: JobSpec) -> Double? {
        spec.effectiveParam("guidance")?.doubleValue ?? spec.effectiveParam("guidanceScale")?.doubleValue
    }
}

/// Submit-time validation: everything a caller can fix is rejected here with a 4xx, never discovered mid-run.
public enum SubmitValidation {
    /// JSON's exact-integer ceiling. Seeds above it would not survive a round trip through any JSON client.
    public static let maxSeed: UInt64 = 9_007_199_254_740_991
    public static let maxCount = 4

    public struct Resolved {
        public var width: Int?
        public var height: Int?
        public var seed: UInt64
        public init(width: Int?, height: Int?, seed: UInt64) { self.width = width; self.height = height; self.seed = seed }
    }

    /// Validates parameters and input *shape* (counts). Input existence, rights and pixel sizes need the library and
    /// are checked by the scheduler.
    public static func validate(_ spec: JobSpec, route: RoutedModel) throws -> Resolved {
        let capability = route.capability
        guard CapabilityShape.served.contains(capability) else {
            throw APIError.unprocessable("unsupported_capability", "\(capability.rawValue) is not served yet.", param: "capability")
        }
        let generative = CapabilityShape.generative.contains(capability)
        guard (1...(generative ? maxCount : 1)).contains(spec.count) else {
            throw APIError.unprocessable("param_out_of_range",
                                         generative ? "n must be between 1 and \(maxCount)." : "\(capability.rawValue) produces one output (n = 1).",
                                         param: "n")
        }
        let seed: UInt64
        if let raw = spec.effectiveParam("seed") {
            guard let value = raw.doubleValue, value >= 0, value.rounded() == value, value <= Double(maxSeed) else {
                throw APIError.unprocessable("param_out_of_range", "seed must be an integer in 0…\(maxSeed).", param: "seed")
            }
            seed = UInt64(value)
        } else {
            seed = UInt64.random(in: 0...(maxSeed - UInt64(maxCount)))
        }

        // Inputs: required slots present, counts within the model's envelope.
        for slot in CapabilityShape.inputSlots(capability) {
            let count = spec.inputs[slot.name]?.count ?? 0
            let max = slot.name == "images" ? route.envelope.maxInputs : 1
            guard count >= slot.min else {
                throw APIError.badRequest("missing_input", "\(capability.rawValue) needs inputs.\(slot.name).", param: "inputs.\(slot.name)")
            }
            guard count <= max else {
                throw APIError.unprocessable("too_many_inputs", "\(route.id) takes at most \(max) image(s) in inputs.\(slot.name).",
                                             param: "inputs.\(slot.name)")
            }
        }

        switch capability {
        case .textToImage, .imageEdit:
            guard let prompt = spec.effectiveParam("prompt")?.stringValue,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError.badRequest("missing_parameter", "prompt is required.", param: "prompt")
            }
            if let steps = spec.effectiveParam("steps") {
                guard let s = steps.intValue, (1...200).contains(s) else {
                    throw APIError.unprocessable("param_out_of_range", "steps must be an integer in 1…200.", param: "steps")
                }
            }
            if let g = spec.effectiveParam("guidance") ?? spec.effectiveParam("guidanceScale") {
                guard let v = g.doubleValue, (0...30).contains(v) else {
                    throw APIError.unprocessable("param_out_of_range", "guidance must be in 0…30.", param: "guidance")
                }
            }
            if let bg = spec.effectiveParam("background")?.stringValue, T2IBackground(rawValue: bg) == nil {
                throw APIError.unprocessable("param_out_of_range", "background must be opaque or transparent.",
                                             param: "background")
            }
            if capability == .imageEdit {
                if let s = spec.effectiveParam("strength") {
                    guard let v = s.doubleValue, (0...1).contains(v) else {
                        throw APIError.unprocessable("param_out_of_range", "strength must be in 0…1.", param: "strength")
                    }
                }
                // Edits default to the model's choice (usually the first input's aspect); an explicit size must fit.
                let asked = spec.effectiveParam("width") != nil || spec.effectiveParam("height") != nil || spec.effectiveParam("size") != nil
                if !asked { return Resolved(width: nil, height: nil, seed: seed) }
            }
            let (w, h) = try size(spec, route: route)
            return Resolved(width: w, height: h, seed: seed)

        case .imageUpscale:
            if let scale = spec.effectiveParam("scale") {
                guard let s = scale.intValue, [2, 4].contains(s) else {
                    throw APIError.unprocessable("param_out_of_range", "scale must be 2 or 4.", param: "scale")
                }
            }
        case .imageRestore, .imageRelight:
            if let s = spec.effectiveParam("strength") {
                guard let v = s.doubleValue, v >= 0, v <= 100 else {
                    throw APIError.unprocessable("param_out_of_range", "strength must be a non-negative number.", param: "strength")
                }
            }
        case .matting, .defectDetect:
            if let kind = spec.effectiveParam("kind")?.stringValue, !["binary", "softAlpha"].contains(kind) {
                throw APIError.unprocessable("param_out_of_range", "kind must be binary or softAlpha.", param: "kind")
            }
            if let t = spec.effectiveParam("threshold") {
                guard let v = t.doubleValue, (0...1).contains(v) else {
                    throw APIError.unprocessable("param_out_of_range", "threshold must be in 0…1.", param: "threshold")
                }
            }
        case .promptSegment:
            let points = spec.effectiveParam("points")?.arrayValue ?? []
            let box = spec.effectiveParam("box")?.arrayValue
            guard !points.isEmpty || box != nil else {
                throw APIError.badRequest("missing_parameter", "promptSegment needs points ([[x, y], …]) or box ([x0, y0, x1, y1]).",
                                          param: "points")
            }
            guard points.allSatisfy({ ($0.arrayValue?.compactMap(\.doubleValue).count ?? 0) == 2 }) else {
                throw APIError.unprocessable("param_out_of_range", "points must be [[x, y], …] in input pixels.", param: "points")
            }
            if let labels = spec.effectiveParam("pointLabels")?.arrayValue {
                guard labels.count == points.count, labels.allSatisfy({ $0.intValue == 0 || $0.intValue == 1 }) else {
                    throw APIError.unprocessable("param_out_of_range", "pointLabels must be 0/1, one per point.", param: "pointLabels")
                }
            }
            if let box, box.compactMap(\.doubleValue).count != 4 {
                throw APIError.unprocessable("param_out_of_range", "box must be [x0, y0, x1, y1].", param: "box")
            }
        default:
            break
        }
        return Resolved(width: nil, height: nil, seed: seed)
    }

    /// Requested size → served size: floored to the envelope's multiple and checked against its pixel ceiling.
    /// `fit: "clamp"` shrinks an oversized request (keeping aspect) instead of rejecting it.
    public static func size(_ spec: JobSpec, route: RoutedModel) throws -> (Int, Int) {
        var width = route.defaults.width
        var height = route.defaults.height
        if let size = spec.effectiveParam("size")?.stringValue {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else {
                throw APIError.unprocessable("param_out_of_range", "size must look like 1024x1024.", param: "size")
            }
            (width, height) = (parts[0], parts[1])
        }
        if let w = spec.effectiveParam("width") {
            guard let v = w.intValue, v > 0 else {
                throw APIError.unprocessable("param_out_of_range", "width must be a positive integer.", param: "width")
            }
            width = v
        }
        if let h = spec.effectiveParam("height") {
            guard let v = h.intValue, v > 0 else {
                throw APIError.unprocessable("param_out_of_range", "height must be a positive integer.", param: "height")
            }
            height = v
        }
        if let fitted = route.envelope.fit(width: width, height: height) { return fitted }
        if spec.effectiveParam("fit")?.stringValue == "clamp" { return route.envelope.clamp(width: width, height: height) }
        let side = Int(Double(route.envelope.maxPixels).squareRoot())
        let square = route.envelope.requiresSquare ? " square images only," : ""
        throw APIError.unprocessable(
            "out_of_envelope",
            "\(width)x\(height) is outside \(route.id)'s envelope:\(square) at most \(route.envelope.maxPixels) pixels "
                + "(e.g. \(side)x\(side)), in multiples of \(route.envelope.multipleOf). Pass fit: \"clamp\" to adjust.",
            param: "width")
    }
}

extension JobSpec {
    /// The prompt the model sees: the brand's composition, else the caller's.
    public var runPrompt: String { brandApplied?.effectivePrompt ?? param("prompt")?.stringValue ?? "" }
    public var runNegativePrompt: String? { brandApplied?.effectiveNegative ?? param("negativePrompt")?.stringValue }
}
