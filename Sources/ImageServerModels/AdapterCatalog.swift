import Foundation
import ImageServerAPI
import MLXToolKit

/// One adapter in the runtime's catalog (AB-A-0191): what the engine registers (`descriptor`, its id qualified by the
/// registry's namespace) and what hosts show (`info`).
public struct AdapterEntry: Sendable, Equatable {
    public let descriptor: AdapterDescriptor
    public let info: AdapterInfo

    public init(descriptor: AdapterDescriptor, info: AdapterInfo) {
        self.descriptor = descriptor
        self.info = info
    }
}

/// Reads adapter registry format 3 (ltx-lora-registry, AB-A-0193) into catalog entries. Every entry is an
/// `AdapterDescriptor` plus registry-only fields; ids are qualified `<namespace>:<id>` so generic ids
/// (`outpaint`, `object-remove`) never collide across registries. The `withdrawn` array is never read: a withdrawn
/// adapter can't register. An entry the engine would refuse (an IC adapter without a footprint, a bad pin) is
/// skipped with its reason, so one bad entry never takes a registry down.
public enum AdapterCatalog {
    public struct Skipped: Sendable, Equatable {
        public var id: String
        public var reason: String

        public init(id: String, reason: String) {
            self.id = id
            self.reason = reason
        }
    }

    private struct Document: Decodable {
        let format: String
        let schemaVersion: Int
        let namespace: String
    }

    /// The registry-only half of an entry.
    private struct Extras: Decodable {
        struct Terms: Decodable {
            let commercialUse: String
            let gated: Bool?
            let notice: String?
            let url: String?
        }
        struct Clearance: Decodable { let level: String }
        struct Slot: Decodable { let role: String }
        let title: String?
        let trigger: String?
        let promptTemplate: String?
        let licenseTerms: Terms
        let status: String
        let clearance: [String: Clearance]?
    }

    public static func decode(_ data: Data) throws -> (entries: [AdapterEntry], skipped: [Skipped]) {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.format == "adapter-registry", document.schemaVersion == 3 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
                "not an adapter registry in format 3 (format \(document.format), schemaVersion \(document.schemaVersion))"))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["adapters"] as? [[String: Any]] else { return ([], []) }
        var entries: [AdapterEntry] = [], skipped: [Skipped] = []
        for item in items {
            let raw = try JSONSerialization.data(withJSONObject: item)
            let local = (item["id"] as? String) ?? "?"
            let id = "\(document.namespace):\(local)"
            do {
                let d = try JSONDecoder().decode(AdapterDescriptor.self, from: raw)
                let extras = try JSONDecoder().decode(Extras.self, from: raw)
                let descriptor = AdapterDescriptor(
                    id: id, title: d.title, kind: d.kind, format: d.format, baseModels: d.baseModels,
                    capabilities: d.capabilities, source: d.source, license: d.license,
                    defaultStrength: d.defaultStrength, strengthRange: d.strengthRange, conditioning: d.conditioning,
                    conditioningGroups: d.conditioningGroups, footprint: d.footprint)
                let problems = descriptor.validationProblems
                guard problems.isEmpty else {
                    skipped.append(Skipped(id: id, reason: problems.joined(separator: "; ")))
                    continue
                }
                let info = AdapterInfo(
                    id: id, title: d.title ?? extras.title ?? local, kind: d.kind.rawValue, baseModels: d.baseModels,
                    capabilities: d.capabilities, trigger: extras.trigger, promptTemplate: extras.promptTemplate,
                    license: d.license.identifier, commercialUse: extras.licenseTerms.commercialUse,
                    licenseGated: extras.licenseTerms.gated ?? false, notice: extras.licenseTerms.notice,
                    licenseURL: extras.licenseTerms.url, defaultStrength: d.defaultStrength,
                    strengthMin: d.strengthRange?.min, strengthMax: d.strengthRange?.max,
                    conditioning: d.conditioning.map {
                        AdapterInfo.AdapterSlot(role: $0.role, media: $0.media.rawValue, required: $0.required,
                                                maxCount: $0.maxCount, note: $0.note)
                    },
                    status: extras.status, clearance: (extras.clearance ?? [:]).mapValues(\.level),
                    bytes: d.source.bytes)
                entries.append(AdapterEntry(descriptor: descriptor, info: info))
            } catch {
                skipped.append(Skipped(id: id, reason: "\(error)"))
            }
        }
        return (entries, skipped)
    }
}
