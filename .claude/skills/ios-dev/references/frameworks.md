# Frameworks Reference

Covers UIKit patterns for when you've chosen UIKit, CoreData best known methods, UIKit↔SwiftUI interop, and performance optimization.

---

## CoreData: When to Use and BKMs

### When to Use CoreData vs SwiftData

| Use CoreData when... | Use SwiftData when... |
|----------------------|----------------------|
| Existing CoreData stack in the project | Greenfield project, iOS 17+ |
| Complex multi-entity migrations needed | Simple or no migrations |
| Fine-grained NSFetchedResultsController needed | Standard query + sort suffices |
| Background processing with NSBatchInsertRequest | Moderate data volume |
| Targeting iOS 16 or earlier | Targeting iOS 17+ only |

SwiftData is CoreData under the hood - they can coexist in the same app via `ModelConfiguration`. Migrate incrementally.

### CoreData Stack Setup (Modern)

Use `NSPersistentCloudKitContainer` if you need CloudKit sync; otherwise `NSPersistentContainer`.

```swift
class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Model")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error { fatalError("CoreData load failed: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}
```

Always set `automaticallyMergesChangesFromParent = true` on the view context so background saves propagate to the UI automatically.

### Context Patterns

**Never write on the view context.** The view context is read-only for UI; all writes go on a background context.

```swift
// Background write - correct
func save(title: String) async throws {
    try await container.performBackgroundTask { context in
        let item = Item(context: context)
        item.title = title
        item.createdAt = Date()
        try context.save()
    }
}

// One-off background context
let bgContext = container.newBackgroundContext()
bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
```

### Fetch Optimization

```swift
// Always set a fetch limit for UI lists
let request = Item.fetchRequest()
request.fetchLimit = 50
request.sortDescriptors = [NSSortDescriptor(keyPath: \Item.createdAt, ascending: false)]

// Use NSPredicate to filter at the store level, not in memory
request.predicate = NSPredicate(format: "isCompleted == NO AND dueDate < %@", Date() as CVarArg)

// Only fetch properties you need - avoids faulting entire objects
request.propertiesToFetch = ["title", "dueDate", "priority"]
request.resultType = .managedObjectResultType
```

Never fetch an entire entity and filter in Swift - that loads everything into memory. Always push predicates to the store.

### Batch Operations (large datasets)

```swift
// Batch insert - bypasses individual object creation, dramatically faster for 1000+ items
let batchInsert = NSBatchInsertRequest(entity: Item.entity(), objects: items.map { $0.dictionary })
try context.execute(batchInsert)

// Batch delete
let fetchRequest: NSFetchRequest<NSFetchRequestResult> = Item.fetchRequest()
fetchRequest.predicate = NSPredicate(format: "isArchived == YES")
let batchDelete = NSBatchDeleteRequest(fetchRequest: fetchRequest)
batchDelete.resultType = .resultTypeObjectIDs
let result = try context.execute(batchDelete) as? NSBatchDeleteResult
// Merge deleted IDs into view context
NSManagedObjectContext.mergeChanges(
    fromRemoteContextSave: [NSDeletedObjectsKey: result?.result ?? []],
    into: [container.viewContext]
)
```

### Migrations

**Lightweight migration** (adding columns, renaming): set `shouldInferMappingModelAutomatically = true` - CoreData handles it.

**Complex migration** (changing relationships, splitting entities): use a custom `NSMigrationManager` with a mapping model. Never do complex migrations on first launch in a background thread on slow devices without a progress UI.

---

## UIKit Patterns

### UICollectionView Compositional Layout

Use compositional layout for any non-trivial collection. It composes `NSCollectionLayoutItem`, `NSCollectionLayoutGroup`, and `NSCollectionLayoutSection`.

```swift
func makeLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { sectionIndex, environment in
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(80)   // self-sizing
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        return section
    }
}
```

Use `.estimated` height dimensions for self-sizing cells - don't calculate heights manually.

### Diffable Data Sources

Always use `UICollectionViewDiffableDataSource` / `UITableViewDiffableDataSource` for new UIKit lists. Never use `reloadData()` for incremental updates.

```swift
typealias DataSource = UICollectionViewDiffableDataSource<Section, Item.ID>

var dataSource: DataSource!

func configureDataSource() {
    let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item.ID> {
        [weak self] cell, indexPath, itemID in
        guard let item = self?.item(for: itemID) else { return }
        var config = cell.defaultContentConfiguration()
        config.text = item.title
        cell.contentConfiguration = config
    }

    dataSource = DataSource(collectionView: collectionView) {
        collectionView, indexPath, itemID in
        collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: itemID)
    }
}

func applySnapshot(items: [Item], animating: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item.ID>()
    snapshot.appendSections([.main])
    snapshot.appendItems(items.map(\.id))
    dataSource.apply(snapshot, animatingDifferences: animating)
}
```

Use `Item.ID` (not the full `Item`) as the snapshot item type to avoid stale object references across updates.

### UIViewController Lifecycle - Common Mistakes

| Mistake | Fix |
|---------|-----|
| Starting network calls in `viewDidLoad` without cancellation | Use a `Task` stored as a property; cancel in `deinit` or `viewWillDisappear` |
| Layout code in `viewDidLoad` | Constraints can go in `viewDidLoad`; frame-based layout belongs in `viewDidLayoutSubviews` |
| Updating UI from background thread | Always dispatch to `DispatchQueue.main` or use `@MainActor` |
| Strong self in closures passed to long-lived objects | Capture `[weak self]` in completion handlers |

---

## UIKit ↔ SwiftUI Interop

### Embedding SwiftUI in UIKit

```swift
let hostingController = UIHostingController(rootView: MySwiftUIView(model: sharedModel))
addChild(hostingController)
view.addSubview(hostingController.view)
hostingController.view.translatesAutoresizingMaskIntoConstraints = false
NSLayoutConstraint.activate([...])
hostingController.didMove(toParent: self)
```

Always call `addChild` / `didMove(toParent:)` - skipping this breaks the responder chain and lifecycle events.

### Embedding UIKit in SwiftUI

```swift
struct MapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.setRegion(region, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView
        init(_ parent: MapView) { self.parent = parent }
    }
}
```

Key rules:
- `makeUIView` - create and configure once; don't set state here
- `updateUIView` - called every time SwiftUI state changes; keep it idempotent
- Use `Coordinator` (a `Coordinator: NSObject`) for delegates and callbacks that need to communicate back into SwiftUI

### Sharing State Across the Bridge

Don't pass `@Binding` through `UIHostingController` if you can avoid it - it works but creates a tight coupling. Instead, inject a shared `@Observable` model that both UIKit and SwiftUI read from directly.

```swift
// Shared observable model
@Observable class AppState {
    var selectedItem: Item?
}

// UIKit side
let state = AppState()
let hosting = UIHostingController(rootView: DetailView(state: state))

// UIKit can also mutate state
state.selectedItem = items[indexPath.row]  // SwiftUI re-renders automatically
```

---

## Performance Reference

### Instruments Workflow

1. **Profile on device, not simulator.** Simulator uses Mac CPU/GPU - numbers are not representative.
2. **Time Profiler** - find CPU hotspots. Sort by "Self" time to find the actual offender, not just the callsite.
3. **Hangs instrument** - finds main thread blocks over 250ms. A hang is always a symptom of synchronous work on main.
4. **Core Data instrument** - shows fetch durations, faults, and context saves. Excessive faulting is a common surprise.
5. **Memory Graph** - detect retain cycles. Any object that should have been deallocated but appears in the graph is a leak.

### SwiftUI-Specific Performance

- Prefer `List` over `ScrollView + ForEach` for any row-based content - `List` is lazy, `ScrollView + ForEach` renders all rows eagerly
- Use `@Observable` instead of `ObservableObject` - it only invalidates views that read changed properties; `@Published` invalidates the entire view tree
- Avoid expensive computed properties on `@Observable` models - they recompute on every access; cache with a stored property
- Use `equatable` conformance on views with `EquatableView` to skip re-renders when inputs haven't changed
- `.drawingGroup()` rasterizes complex views to a single layer - useful for views with many overlapping shapes or effects

### Image Performance

```swift
// Remote: AsyncImage with phase handling
AsyncImage(url: item.imageURL) { phase in
    switch phase {
    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
    case .failure: Image(systemName: "photo")
    case .empty: ProgressView()
    @unknown default: EmptyView()
    }
}

// Local high-res: load off main
Task.detached(priority: .userInitiated) {
    let image = await loadAndDownsample(url: localURL, targetSize: thumbnailSize)
    await MainActor.run { self.thumbnail = image }
}
```

Use `ImageRenderer` for generating images from SwiftUI views - but only off the main thread.

---

## SwiftData BKMs

### `@ModelActor` for background work
Never write to SwiftData on the main context from a background thread. Use `@ModelActor` to create an isolated background actor with its own `ModelContext`:

```swift
@ModelActor
actor SyncActor {
    func importItems(_ data: [ItemPayload]) throws {
        for payload in data {
            let item = Item(from: payload)
            modelContext.insert(item)
        }
        try modelContext.save()
    }
}
```

### `FetchDescriptor` over `@Query` for dynamic predicates
`@Query` is great for static fetches in views. For dynamic filtering (user search, runtime conditions), use `FetchDescriptor` in your ViewModel or actor:

```swift
var descriptor = FetchDescriptor<Item>(
    predicate: #Predicate { $0.isCompleted == false },
    sortBy: [SortDescriptor(\.dueDate)]
)
descriptor.fetchLimit = 50
descriptor.includePendingChanges = true
let items = try modelContext.fetch(descriptor)
```

### Predicate ordering matters
SwiftData translates `#Predicate` to SQL. Put the most selective conditions first - filtering on an indexed property (like a UUID or enum) before a string `contains` dramatically reduces scan time.

### Relationship initializer crash
Accessing a relationship on a `@Model` object before it's fully inserted into a `ModelContext` will crash. Always insert the object first, then configure relationships.

```swift
// ❌ Crash - category not inserted yet
let item = Item()
item.category = Category(name: "Work") // crash

// ✅ Insert both first
let category = Category(name: "Work")
modelContext.insert(category)
let item = Item()
modelContext.insert(item)
item.category = category
```

### Prefetching relationships
SwiftData lazy-loads relationships by default. If you're rendering a list that always shows related objects (e.g., items with their category name), prefetch to avoid N+1 faulting:

```swift
descriptor.relationshipKeyPathsForPrefetching = [\.category]
```

---

## CloudKit Integration BKMs

### When to use `NSPersistentCloudKitContainer`
Use it when you need automatic CloudKit sync with an existing CoreData stack. For SwiftData + CloudKit, set `cloudKitDatabase: .automatic` in your `ModelConfiguration`. Both use the same underlying CKContainer.

### Operation throttling
CloudKit enforces per-database rate limits. Batch your writes - don't call `CKModifyRecordsOperation` in a tight loop. Use a coalescing queue: accumulate changes for 0.5–1s, then flush as a single batch operation.

```swift
// Coalesce with a debounced Task
private var syncTask: Task<Void, Never>?

func scheduleSync() {
    syncTask?.cancel()
    syncTask = Task {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        await flushPendingChanges()
    }
}
```

### Batch limits
`CKModifyRecordsOperation` has a hard limit of 400 records per operation. Always chunk large syncs:

```swift
for chunk in records.chunked(into: 400) {
    let op = CKModifyRecordsOperation(recordsToSave: chunk)
    op.savePolicy = .changedKeys
    database.add(op)
}
```

### Retry with exponential backoff
CloudKit returns `CKError.requestRateLimited` and `CKError.serviceUnavailable` under load. Always implement exponential backoff:

```swift
func retry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
    var delay: UInt64 = 1_000_000_000 // 1s
    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch let error as CKError where error.isRetryable && attempt < maxAttempts {
            try await Task.sleep(nanoseconds: delay)
            delay *= 2
        }
    }
    return try await operation() // final attempt, let it throw
}

extension CKError {
    var isRetryable: Bool {
        [.requestRateLimited, .serviceUnavailable, .networkUnavailable, .networkFailure].contains(code)
    }
}
```

### Client timestamps vs server timestamps
Never rely on `CKRecord.modificationDate` for conflict resolution in offline-first apps - it reflects server receive time, not when the user made the change. Store a client-side `lastModifiedAt: Date` on your model and use that for conflict logic.

### Asset copying
`CKAsset` points to a file URL on disk. The file must exist and remain accessible until the operation completes. Copy assets to a stable location (e.g., `Caches/ckassets/`) before uploading - never reference temp files or in-memory data directly.
