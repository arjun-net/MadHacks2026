import Observation
import Foundation

@Observable
@MainActor
final class ActivityViewModel {
    let store: CampusStore

    init(store: CampusStore) {
        self.store = store
    }

    var campus: Campus { store.campus }
    var snapshot: CampusSnapshot? { store.snapshot }
    var loadState: LoadState { store.state }

    var busiest: [AreaActivity] { snapshot?.busiest(5) ?? [] }

    var quietSpots: [AreaActivity] {
        // Prefer genuinely useful quiet places (libraries, unions, academic buildings) over a stadium.
        let useful: Set<AreaCategory> = [.library, .union, .academic, .dining, .outdoors]
        let candidates = snapshot?.areas.filter { useful.contains($0.area.category) } ?? []
        return Array(candidates.sorted { $0.intensity < $1.intensity }.prefix(3))
    }

    var allAreas: [AreaActivity] { snapshot?.areasByActivity ?? [] }

    var participantsText: String {
        guard let snapshot else { return "—" }
        return "≈ " + Formatting.number(snapshot.participantCount)
    }

    var activeAreasText: String {
        guard let snapshot else { return "—" }
        return "\(snapshot.activeAreaCount) of \(snapshot.areas.count)"
    }

    func refresh() async {
        await store.refresh()
    }
}
