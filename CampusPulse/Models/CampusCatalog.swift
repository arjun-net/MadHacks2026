import Foundation

/// Supported campuses. In production this list would come from the backend.
enum CampusCatalog {
    static let madison = Campus(
        id: "uw-madison",
        name: "University of Wisconsin–Madison",
        shortName: "UW–Madison",
        location: "Madison, WI",
        center: Coordinate(43.0714, -89.4074),
        latitudeSpan: 0.014,
        longitudeSpan: 0.034,
        // The 20 tracked buildings: the same ids, names and outlines as
        // Resources/Buildings/buildings-uw-madison.json and the server's building grid, so a
        // reading counts for the building the database names. Popularity follows ping counts.
        areas: [
            CampusArea(id: "abbie_142", name: "The Abbie", shortName: "The Abbie",
                       category: .housing, coordinate: Coordinate(43.077493, -89.392528), radiusMeters: 12, popularity: 1.0),
            CampusArea(id: "hub_madison", name: "Collegiate Madison", shortName: "Collegiate",
                       category: .housing, coordinate: Coordinate(43.075409, -89.3971), radiusMeters: 15, popularity: 0.9),
            CampusArea(id: "laurel_commons", name: "Laurel Commons", shortName: "Laurel Commons",
                       category: .housing, coordinate: Coordinate(43.065308, -89.398349), radiusMeters: 36, popularity: 0.72),
            CampusArea(id: "chazen_museum", name: "Chazen Museum of Art", shortName: "Chazen",
                       category: .academic, coordinate: Coordinate(43.073898, -89.398736), radiusMeters: 32, popularity: 0.65, symbolOverride: "paintpalette.fill"),
            CampusArea(id: "embassy_505", name: "The Embassy", shortName: "The Embassy",
                       category: .housing, coordinate: Coordinate(43.072874, -89.394365), radiusMeters: 19, popularity: 0.65),
            CampusArea(id: "sba_1917", name: "1917 University Ave", shortName: "1917 University",
                       category: .housing, coordinate: Coordinate(43.073346, -89.41868), radiusMeters: 11, popularity: 0.61),
            CampusArea(id: "college_library", name: "College Library (Helen C. White Hall)", shortName: "College Library",
                       category: .library, coordinate: Coordinate(43.076663, -89.401329), radiusMeters: 42, popularity: 0.56),
            CampusArea(id: "the_regent", name: "The Regent", shortName: "The Regent",
                       category: .housing, coordinate: Coordinate(43.068019, -89.410057), radiusMeters: 40, popularity: 0.55),
            CampusArea(id: "lucky_777", name: "Lucky Apartments", shortName: "Lucky",
                       category: .housing, coordinate: Coordinate(43.072697, -89.397945), radiusMeters: 55, popularity: 0.54),
            CampusArea(id: "memorial_library", name: "Memorial Library", shortName: "Memorial Library",
                       category: .library, coordinate: Coordinate(43.075381, -89.39797), radiusMeters: 42, popularity: 0.53),
            CampusArea(id: "ebling_library", name: "Ebling Library (Health Sciences Learning Center)", shortName: "Ebling Library",
                       category: .library, coordinate: Coordinate(43.0726, -89.40985), radiusMeters: 32, popularity: 0.49),
            CampusArea(id: "oak_tree", name: "Oak Tree Apartments", shortName: "Oak Tree",
                       category: .housing, coordinate: Coordinate(43.072965, -89.422222), radiusMeters: 23, popularity: 0.49),
            CampusArea(id: "wendt_library", name: "Wendt Commons (Engineering Library)", shortName: "Wendt Commons",
                       category: .library, coordinate: Coordinate(43.071461, -89.408642), radiusMeters: 24, popularity: 0.48),
            CampusArea(id: "constellation", name: "The Constellation", shortName: "Constellation",
                       category: .housing, coordinate: Coordinate(43.07452, -89.392817), radiusMeters: 10, popularity: 0.48),
            CampusArea(id: "wisconsin_historical_society", name: "Wisconsin Historical Society", shortName: "Historical Society",
                       category: .library, coordinate: Coordinate(43.075404, -89.400077), radiusMeters: 34, popularity: 0.48, symbolOverride: "building.columns.fill"),
            CampusArea(id: "towers_on_state", name: "The Towers on State", shortName: "Towers on State",
                       category: .housing, coordinate: Coordinate(43.075149, -89.395728), radiusMeters: 20, popularity: 0.47),
            CampusArea(id: "morgridge_institute", name: "Morgridge Institute for Research", shortName: "Morgridge Institute",
                       category: .academic, coordinate: Coordinate(43.072935, -89.408178), radiusMeters: 45, popularity: 0.47, symbolOverride: "flask.fill"),
            CampusArea(id: "art_library", name: "Kohler Art Library (Elvehjem Building)", shortName: "Art Library",
                       category: .library, coordinate: Coordinate(43.073913, -89.399407), radiusMeters: 23, popularity: 0.46),
            CampusArea(id: "theory_madison", name: "Theory Madison", shortName: "Theory",
                       category: .housing, coordinate: Coordinate(43.074089, -89.39711), radiusMeters: 35, popularity: 0.46),
            CampusArea(id: "morgridge_hall", name: "Morgridge Hall (College of Computing & AI)", shortName: "Morgridge Hall",
                       category: .academic, coordinate: Coordinate(43.072873, -89.406636), radiusMeters: 45, popularity: 0.4, symbolOverride: "laptopcomputer"),
        ],
        participationScale: 1.0
    )

    static let michigan = Campus(
        id: "umich",
        name: "University of Michigan",
        shortName: "Michigan",
        location: "Ann Arbor, MI",
        center: Coordinate(42.2765, -83.7385),
        latitudeSpan: 0.011,
        longitudeSpan: 0.018,
        areas: [
            CampusArea(id: "shapiro", name: "Shapiro Library", shortName: "Shapiro Library",
                       category: .library, coordinate: Coordinate(42.2756, -83.7371), radiusMeters: 60, popularity: 1.0),
            CampusArea(id: "michigan-union", name: "Michigan Union", shortName: "Michigan Union",
                       category: .union, coordinate: Coordinate(42.2751, -83.7416), radiusMeters: 65, popularity: 0.92),
            CampusArea(id: "the-diag", name: "The Diag", shortName: "The Diag",
                       category: .outdoors, coordinate: Coordinate(42.2769, -83.7382), radiusMeters: 80, popularity: 0.7),
            CampusArea(id: "ccrb", name: "Central Campus Rec Building", shortName: "CCRB",
                       category: .recreation, coordinate: Coordinate(42.2789, -83.7343), radiusMeters: 55, popularity: 0.7),
            CampusArea(id: "south-quad", name: "South Quad Dining", shortName: "South Quad",
                       category: .dining, coordinate: Coordinate(42.2735, -83.7423), radiusMeters: 55, popularity: 0.8),
            CampusArea(id: "mojo", name: "Mosher-Jordan Dining", shortName: "MoJo Dining",
                       category: .dining, coordinate: Coordinate(42.2799, -83.7318), radiusMeters: 50, popularity: 0.62),
            CampusArea(id: "ross", name: "Ross School of Business", shortName: "Ross",
                       category: .academic, coordinate: Coordinate(42.2731, -83.7380), radiusMeters: 60, popularity: 0.75),
            CampusArea(id: "chemistry", name: "Chemistry Building", shortName: "Chemistry",
                       category: .academic, coordinate: Coordinate(42.2783, -83.7396), radiusMeters: 50, popularity: 0.6,
                       symbolOverride: "flask.fill"),
        ],
        participationScale: 0.85,
        isAvailable: false
    )

    static let stanford = Campus(
        id: "stanford",
        name: "Stanford University",
        shortName: "Stanford",
        location: "Stanford, CA",
        center: Coordinate(37.4265, -122.1697),
        latitudeSpan: 0.012,
        longitudeSpan: 0.02,
        areas: [
            CampusArea(id: "green-library", name: "Green Library", shortName: "Green Library",
                       category: .library, coordinate: Coordinate(37.4268, -122.1672), radiusMeters: 60, popularity: 1.0),
            CampusArea(id: "tresidder", name: "Tresidder Union", shortName: "Tresidder",
                       category: .union, coordinate: Coordinate(37.4241, -122.1706), radiusMeters: 60, popularity: 0.9),
            CampusArea(id: "main-quad", name: "Main Quad", shortName: "Main Quad",
                       category: .outdoors, coordinate: Coordinate(37.4275, -122.1700), radiusMeters: 80, popularity: 0.7),
            CampusArea(id: "huang", name: "Huang Engineering Center", shortName: "Huang",
                       category: .academic, coordinate: Coordinate(37.4276, -122.1774), radiusMeters: 55, popularity: 0.75,
                       symbolOverride: "gearshape.2.fill"),
            CampusArea(id: "arrillaga-dining", name: "Arrillaga Family Dining", shortName: "Arrillaga Dining",
                       category: .dining, coordinate: Coordinate(37.4251, -122.1625), radiusMeters: 50, popularity: 0.75),
        ],
        // Just launched: too few participants yet, which exercises the privacy-suppressed empty state.
        participationScale: 0.025,
        isAvailable: false
    )

    static let all: [Campus] = [madison, michigan, stanford]

    /// Campuses with data, in catalog order.
    static var available: [Campus] { all.filter(\.isAvailable) }

    static func campus(withID id: String) -> Campus? {
        all.first { $0.id == id }
    }
}
