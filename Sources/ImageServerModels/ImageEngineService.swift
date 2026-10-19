import ForgeCore
import Foundation
import ImageServerAPI
import MLXHubMetadata
import MLXServeCore
import MLXToolKit
import OSLog

private let log = Logger(subsystem: "com.xocialize.mlx-image-server", category: "engine")

/// The engine, the catalog and routing. ForgeCore constructs the engine (so its processing tiers register through
/// the one shared registration table) with `.advisory` enforcement: research-only weights register, and the
/// advisory travels with every model, job and asset instead of blocking.
public actor ImageEngineService: ImageModelDirectory, ModelRouter {
    public nonisolated let engine: MLXServeEngine
    public nonisolated let entries: [CatalogEntry]
    /// Settings → "Allow non-commercial & research models". The app is non-commercial, so the default is on.
    public var allowRestricted: Bool

    private var registered: [ModelID: PackageID] = [:]
    private var manifests: [ModelID: PackageManifest] = [:]
    private var failures: [ModelID: String] = [:]
    private var stamps: [ModelID: LicenseStamp] = [:]
    /// The adapter catalog the engine holds (AB-A-0191), by qualified id.
    private var adapterEntries: [String: AdapterEntry] = [:]
    /// Adapters that didn't register, and why (a skipped registry entry, or an engine refusal).
    private var adapterFailures: [String: String] = [:]
    /// Per model and capability: what the surface accepts, and the catalog adapters that fit it.
    private var adapterSupport: [ModelID: [Capability: AdapterSupport]] = [:]
    private var compatibleAdapters: [ModelID: [Capability: [AdapterDescriptor]]] = [:]

    init(engine: MLXServeEngine, entries: [CatalogEntry], allowRestricted: Bool) {
        self.engine = engine
        self.entries = entries
        self.allowRestricted = allowRestricted
    }

    /// Builds the ForgeCore service, attaches the model store (**before** any registration), registers ForgeCore's
    /// tiers and then our packages. The returned `ForgeEngineService` must be kept alive by the caller.
    ///
    /// `adapters` is the adapter catalog (`ModelCatalog.adapters()` in ImageServerCatalog): registered with the engine
    /// after the packages, so each model lists the adapters its surfaces accept (AB-A-0191).
    @MainActor
    public static func bootstrap(storeRoot: URL?, catalog: [CatalogEntry], allowRestricted: Bool = true,
                                 adapters: [AdapterEntry] = []) async -> (ImageEngineService, ForgeEngineService) {
        let externals = catalog.compactMap { entry -> ExternalRegistration? in
            guard case .package(_, let register) = entry.source else { return nil }
            return ExternalRegistration(name: entry.id.rawValue, capability: entry.capabilities.first ?? .textToImage,
                                        register: register)
        }
        let forge = ForgeEngineService(policy: .permissiveOnly, enforcement: .advisory, externalRegistrations: externals)
        await forge.attachModelStore(root: storeRoot)
        await forge.registerAll()

        var outcomes: [(ModelID, PackageID?, String?)] = []
        for entry in catalog {
            switch entry.source {
            case .package:
                let outcome = forge.externalOutcomes.first { $0.name == entry.id.rawValue }
                outcomes.append((entry.id, outcome?.packageID, outcome?.failure ?? (outcome == nil ? "not registered" : nil)))
            case .forge(let model):
                outcomes.append((entry.id, forge.packageID(for: model), forge.outcome(for: model)?.failure))
            }
        }
        let service = ImageEngineService(engine: forge.engine, entries: catalog, allowRestricted: allowRestricted)
        await service.recordRegistrations(outcomes)
        await service.registerAdapters(adapters)
        return (service, forge)
    }

    /// Register catalog adapters with the engine, each on its own (one refusal never drops the rest), then work out
    /// which adapters each registered model's surfaces accept.
    public func registerAdapters(_ catalog: [AdapterEntry]) async {
        for entry in catalog {
            do {
                try await engine.registerAdapter(entry.descriptor)
                adapterEntries[entry.descriptor.id] = entry
                adapterFailures[entry.descriptor.id] = nil
            } catch {
                adapterFailures[entry.descriptor.id] = "\(error)"
                log.error("adapter \(entry.descriptor.id, privacy: .public) did not register: \("\(error)", privacy: .public)")
            }
        }
        let descriptors = adapterEntries.values.map(\.descriptor).sorted { $0.id < $1.id }
        adapterSupport = [:]
        compatibleAdapters = [:]
        for entry in entries where registered[entry.id] != nil {
            guard let manifest = manifests[entry.id] ?? entry.manifest else { continue }
            for capability in entry.capabilities {
                guard let support = manifest.surfaces.first(where: { $0.capability == capability })?.adapters
                else { continue }
                adapterSupport[entry.id, default: [:]][capability] = support
                compatibleAdapters[entry.id, default: [:]][capability] =
                    descriptors.filter { support.mismatch($0, capability: capability) == nil }
            }
        }
    }

    /// Every adapter in the catalog, and the ones that didn't register.
    public func adapterCatalog() -> (registered: [AdapterInfo], failures: [String: String]) {
        (adapterEntries.values.map(\.info).sorted { $0.id < $1.id }, adapterFailures)
    }

    /// What fetching these adapters would download now: the engine's consent preview. Only adapters not yet
    /// verified on disk appear.
    public func adapterDownloadCheck(_ ids: [String]) async -> MaterializationPreview {
        await engine.adapterMaterializationPreview(ids)
    }

    /// Fetch and hash-check adapters now (the consent path: preview, ask, then this).
    public func prepareAdapters(_ ids: [String]) async throws {
        try await engine.prepareAdapters(ids)
    }

    func recordRegistrations(_ outcomes: [(ModelID, PackageID?, String?)]) async {
        let advisories = await engine.licenseAdvisories
        for (id, packageID, failure) in outcomes {
            guard let entry = entries.first(where: { $0.id == id }) else { continue }
            if let packageID {
                registered[id] = packageID
                if let manifest = entry.manifest {
                    manifests[id] = manifest
                } else if let manifest = await engine.manifest(for: packageID) {
                    manifests[id] = manifest
                }
            } else {
                failures[id] = failure ?? "registration failed"
                log.error("\(id.rawValue, privacy: .public) did not register: \(failure ?? "unknown", privacy: .public)")
            }
            if let manifest = manifests[id] ?? entry.manifest {
                let lines = advisories.filter { $0.repo == manifest.provenance.sourceRepo }.map(\.summary)
                stamps[id] = LicenseClassifier.stamp(for: manifest.license, advisories: lines)
            }
        }
    }

    public func setAllowRestricted(_ allow: Bool) { allowRestricted = allow }

    // MARK: - ImageModelDirectory

    public func models() async -> [ModelInfo] {
        var result: [ModelInfo] = []
        for entry in entries { result.append(await info(for: entry)) }
        return result
    }

    public func model(_ id: ModelID) async -> ModelInfo? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return await info(for: entry)
    }

    public func capabilities() async -> [Capability] {
        var seen: [Capability] = []
        for entry in entries where registered[entry.id] != nil {
            for c in entry.capabilities where !seen.contains(c) { seen.append(c) }
        }
        return seen
    }

    private func info(for entry: CatalogEntry) async -> ModelInfo {
        let packageID = registered[entry.id]
        var downloaded = false
        var resident = false
        var residentBytes: UInt64?
        if let packageID, let capability = entry.capabilities.first {
            if entry.localSnapshot != nil {
                downloaded = true
            } else {
                downloaded = !(await engine.needsDownload(capability, package: packageID))
            }
            if let bytes = await engine.residentPackages[packageID] {
                resident = true
                residentBytes = bytes
            }
        }
        let defaultFor = await defaultCapabilities(of: entry)
        let manifest = manifests[entry.id] ?? entry.manifest
        return ModelInfo(
            id: entry.id, displayName: entry.displayName, summary: entry.summary, capabilities: entry.capabilities,
            defaultFor: defaultFor, maturity: entry.maturity, license: stamp(for: entry),
            sourceRepo: manifest?.provenance.sourceRepo ?? "", revision: manifest?.provenance.revision ?? "",
            envelope: entry.envelope, defaults: entry.defaults, footprintBytes: footprint(entry),
            state: ModelState(downloaded: downloaded, resident: resident, residentBytes: residentBytes,
                              problem: failures[entry.id].map { "not registered: \($0)" }),
            requestKeys: entry.requestKeys,
            adapters: adapterInfos(for: entry))
    }

    /// The catalog adapters any of the entry's surfaces accept, once each.
    private func adapterInfos(for entry: CatalogEntry) -> [AdapterInfo] {
        var seen = Set<String>()
        return entry.capabilities.flatMap { compatibleAdapters[entry.id]?[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }
            .compactMap { adapterEntries[$0.id]?.info }
    }

    private func footprint(_ entry: CatalogEntry) -> UInt64? {
        guard let footprints = (manifests[entry.id] ?? entry.manifest)?.requirements.footprints else { return nil }
        if let quant = entry.quant, let match = footprints.first(where: { $0.quant == quant }) { return match.residentBytes }
        return footprints.first?.residentBytes
    }

    private func stamp(for entry: CatalogEntry) -> LicenseStamp {
        if let stamp = stamps[entry.id] { return stamp }
        if let manifest = manifests[entry.id] ?? entry.manifest {
            return LicenseClassifier.stamp(for: manifest.license, advisories: [])
        }
        return LicenseStamp(licenseClass: .restricted, weightLicenses: [], portCodeLicense: "unknown",
                            advisories: ["Licence unknown: the package is not registered."])
    }

    private func defaultCapabilities(of entry: CatalogEntry) async -> [Capability] {
        var result: [Capability] = []
        for capability in entry.capabilities {
            if let routed = try? await route(capability, model: nil), routed.id == entry.id { result.append(capability) }
        }
        return result
    }

    // MARK: - ModelRouter

    public func route(_ capability: Capability, model: ModelID?) async throws -> RoutedModel {
        if let model {
            guard let entry = entries.first(where: { $0.id == model }) else {
                throw APIError.unprocessable("unknown_model", "No model named '\(model)'.", param: "model")
            }
            guard entry.capabilities.contains(capability) else {
                throw APIError.unprocessable("unsupported_capability",
                                             "'\(model)' does not serve \(capability.rawValue).", param: "model")
            }
            guard let packageID = registered[entry.id] else {
                throw APIError.unavailable("'\(model)' is not available: \(failures[entry.id] ?? "not registered").")
            }
            let stamp = stamp(for: entry)
            if stamp.licenseClass != .permissive && !allowRestricted {
                throw APIError.conflict("license_not_allowed",
                                        "'\(model)' has \(stamp.licenseClass.rawValue) terms and non-commercial models are disabled in Settings.")
            }
            return routed(entry, packageID: packageID, capability: capability)
        }

        // Default routing: permissive ∧ prod only. Preferred-for-this-capability first, then resident, then catalog order.
        let candidates = entries.filter { entry in
            entry.capabilities.contains(capability) && registered[entry.id] != nil && entry.maturity == .prod
                && stamp(for: entry).licenseClass == .permissive
        }
        guard !candidates.isEmpty else {
            let named = entries.filter { $0.capabilities.contains(capability) && registered[$0.id] != nil }
                .map(\.id.rawValue)
            guard !named.isEmpty else {
                throw APIError.unprocessable("unsupported_capability", "No model serves \(capability.rawValue).",
                                             param: "capability")
            }
            throw APIError.unprocessable(
                "no_permissive_model",
                "No permissive production model serves \(capability.rawValue); name one of: \(named.joined(separator: ", ")).",
                param: "model")
        }
        let resident = Set(await engine.residentPackages.keys)
        let ranked = candidates.enumerated().sorted { a, b in
            func key(_ e: CatalogEntry) -> Int {
                (e.preferredFor.contains(capability) ? 0 : 2) + (resident.contains(registered[e.id]!) ? 0 : 1)
            }
            return (key(a.element), a.offset) < (key(b.element), b.offset)
        }
        let chosen = ranked[0].element
        return routed(chosen, packageID: registered[chosen.id]!, capability: capability)
    }

    public func route(_ capability: Capability, model: ModelID?, adapters: [String]) async throws -> RoutedModel {
        guard model == nil, !adapters.isEmpty else { return try await route(capability, model: model) }
        let wanted = Set(adapters)
        if let routed = try? await route(capability, model: nil), wanted.isSubset(of: Set(routed.adapters.map(\.id))) {
            return routed
        }
        // The adapter implies its base model (AB-D-0155): the first model that takes every named adapter, prod before
        // wip, under the same licence rule as naming it.
        let fitting = entries.filter { entry in
            entry.capabilities.contains(capability) && registered[entry.id] != nil
                && wanted.isSubset(of: Set((compatibleAdapters[entry.id]?[capability] ?? []).map(\.id)))
        }
        if let chosen = fitting.first(where: { $0.maturity == .prod }) ?? fitting.first {
            return try await route(capability, model: chosen.id)
        }
        let unknown = adapters.filter { adapterEntries[$0] == nil }
        throw APIError.unprocessable(
            "unsupported_parameter",
            unknown.isEmpty
                ? "No model serving \(capability.rawValue) takes every adapter named (\(adapters.joined(separator: ", ")))."
                : "Not in the adapter catalog: \(unknown.joined(separator: ", ")).",
            param: "adapters")
    }

    public func modelID(forPackage packageID: String) async -> ModelID? {
        registered.first(where: { $0.value.rawValue == packageID })?.key
    }

    public func registeredModels() async -> [RegisteredModel] {
        entries.compactMap { entry in
            registered[entry.id].map {
                RegisteredModel(id: entry.id, packageID: $0.rawValue, capabilities: entry.capabilities,
                                footprintBytes: footprint(entry))
            }
        }
    }

    private func routed(_ entry: CatalogEntry, packageID: PackageID, capability: Capability) -> RoutedModel {
        let manifest = manifests[entry.id] ?? entry.manifest
        return RoutedModel(id: entry.id, packageID: packageID.rawValue, capability: capability,
                           displayName: entry.displayName, license: stamp(for: entry),
                           envelope: entry.envelope(for: capability), defaults: entry.defaults,
                           sourceRepo: manifest?.provenance.sourceRepo ?? "", revision: manifest?.provenance.revision ?? "",
                           footprintBytes: footprint(entry),
                           requestKeys: entry.requestKeys.filter { $0.capabilities.contains(capability) },
                           adapterSupport: adapterSupport[entry.id]?[capability],
                           adapters: compatibleAdapters[entry.id]?[capability] ?? [])
    }
}
