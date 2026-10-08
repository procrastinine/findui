import SearchBackend
import Combine
import Foundation

/// The shared persisted library, never a live search or result set.
@MainActor
final class SearchLibraryStore: ObservableObject {
    let persistence: AppPersistence
    @Published var value = PersistedLibrary()
    @Published private(set) var saveError: String?
    private var loadTask: Task<PersistedLibrary, Error>?
    private var loaded = false
    private var pendingSave: Task<Void, Never>?
    private var maintenance: [UUID: (configuration: IndexConfiguration, service: IndexMaintenance, task: Task<Void, Never>)] = [:]
    private var suspended = Set<UUID>()
    private var isShuttingDown = false

    init(persistence: AppPersistence = AppPersistence()) {
        self.persistence = persistence
    }

    func load() async throws -> PersistedLibrary {
        if !loaded {
            if loadTask == nil {
                let persistence = persistence
                loadTask = Task { try await persistence.loadLibrary() }
            }
            let restored = try await loadTask!.value
            if !loaded { value = restored; loaded = true; reconcileMaintenance() }
        }
        return value
    }

    func save() {
        reconcileMaintenance()
        let snapshot = value, previous = pendingSave, persistence = persistence
        // Serialize writes in edit order. A slower earlier save cannot replace
        // history or pins added by another window in the meantime.
        pendingSave = Task { [weak self] in
            await previous?.value
            do {
                try await persistence.saveLibrary(snapshot)
                self?.saveError = nil
            } catch { self?.saveError = error.localizedDescription }
        }
    }

    func flush() async { await pendingSave?.value }

    func stopMaintenance(for id: UUID) async {
        suspended.insert(id)
        guard let job = maintenance.removeValue(forKey: id) else { return }
        job.task.cancel()
        await job.service.stop()
        await job.task.value
    }
    func resumeMaintenance(for id: UUID) { suspended.remove(id); reconcileMaintenance() }

    func shutdown() async {
        isShuttingDown = true
        let jobs = Array(maintenance.values)
        maintenance.removeAll()
        // Cancel every watcher before waiting for any one of them. Save user
        // edits first; a slow filesystem must not hold that write hostage.
        for job in jobs { job.task.cancel() }
        await flush()
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    await job.service.stop()
                    await job.task.value
                }
            }
        }
    }

    private func reconcileMaintenance() {
        guard !isShuttingDown else { return }
        let enabled = value.managedIndexes.filter { $0.automaticRefresh == true && !suspended.contains($0.id) }
        for id in Array(maintenance.keys) where !enabled.contains(where: { $0.id == id }) {
            let job = maintenance.removeValue(forKey: id)!
            job.task.cancel(); Task { await job.service.stop() }
        }
        for index in enabled {
            let configuration = IndexConfiguration(index)
            if maintenance[index.id]?.configuration == configuration { continue }
            let previous = maintenance.removeValue(forKey: index.id)
            let output = persistence.indexURL(index.id)
            let service = IndexMaintenance(configuration: configuration, output: output, published: { [weak self] artifact in
                await self?.publishedIndex(artifact)
            }, failed: { [weak self] message in
                await self?.indexFailure(index.id, message: message)
            })
            let task = Task { [weak self] in
                previous?.task.cancel(); await previous?.service.stop()
                do { try Task.checkCancellation(); try await service.start() }
                catch is CancellationError { }
                catch { self?.indexFailure(index.id, message: error.localizedDescription) }
            }
            maintenance[index.id] = (configuration, service, task)
        }
    }

    private func publishedIndex(_ artifact: IndexArtifact) {
        guard !isShuttingDown,
              let position = value.managedIndexes.firstIndex(where: { $0.id == artifact.metadata.id }),
              value.managedIndexes[position].automaticRefresh == true else { return }
        var metadata = artifact.metadata; metadata.automaticRefresh = true
        value.managedIndexes[position] = metadata
        save()
    }

    private func indexFailure(_ id: UUID, message: String) {
        guard maintenance[id] != nil, let position = value.managedIndexes.firstIndex(where: { $0.id == id }) else { return }
        value.managedIndexes[position].warning = message
        save()
    }
}
