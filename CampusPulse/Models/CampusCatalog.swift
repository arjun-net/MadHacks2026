import Foundation

/// Supported campuses. In production this list would come from the backend.
enum CampusCatalog {
    static let madison = Campus(
        id: "uw-madison",
        name: "University of Wisconsin–Madison",
        shortName: "UW–Madison",
        location: "Madison, WI",
        center: Coordinate(43.0734, -89.4058),
        latitudeSpan: 0.0085,
        longitudeSpan: 0.0205,
        areas: [
            CampusArea(id: "college-library", name: "College Library", shortName: "College Library",
                       category: .library, coordinate: Coordinate(43.0768, -89.4013), radiusMeters: 70, popularity: 1.0),
            CampusArea(id: "memorial-union", name: "Memorial Union", shortName: "Memorial Union",
                       category: .union, coordinate: Coordinate(43.0764, -89.3996), radiusMeters: 75, popularity: 0.95),
            CampusArea(id: "memorial-library", name: "Memorial Library", shortName: "Memorial Library",
                       category: .library, coordinate: Coordinate(43.0751, -89.3982), radiusMeters: 60, popularity: 0.78),
            CampusArea(id: "union-south", name: "Union South", shortName: "Union South",
                       category: .union, coordinate: Coordinate(43.0720, -89.4078), radiusMeters: 70, popularity: 0.88),
            CampusArea(id: "the-nick", name: "Nicholas Recreation Center", shortName: "The Nick",
                       category: .recreation, coordinate: Coordinate(43.0704, -89.3998), radiusMeters: 65, popularity: 0.74),
            CampusArea(id: "gordon-dining", name: "Gordon Dining & Event Center", shortName: "Gordon Dining",
                       category: .dining, coordinate: Coordinate(43.0718, -89.3962), radiusMeters: 55, popularity: 0.82),
            CampusArea(id: "engineering-hall", name: "Engineering Hall", shortName: "Engineering",
                       category: .academic, coordinate: Coordinate(43.0721, -89.4100), radiusMeters: 70, popularity: 0.8,
                       symbolOverride: "gearshape.2.fill"),
            CampusArea(id: "computer-sciences", name: "Computer Sciences", shortName: "Computer Sciences",
                       category: .academic, coordinate: Coordinate(43.0712, -89.4062), radiusMeters: 50, popularity: 0.66,
                       symbolOverride: "laptopcomputer"),
            CampusArea(id: "bascom-hall", name: "Bascom Hall", shortName: "Bascom Hall",
                       category: .academic, coordinate: Coordinate(43.0753, -89.4041), radiusMeters: 60, popularity: 0.55),
            CampusArea(id: "grainger-hall", name: "Grainger Hall", shortName: "Grainger Hall",
                       category: .academic, coordinate: Coordinate(43.0729, -89.4018), radiusMeters: 55, popularity: 0.62),
            CampusArea(id: "van-hise", name: "Van Hise Hall", shortName: "Van Hise",
                       category: .academic, coordinate: Coordinate(43.0757, -89.4074), radiusMeters: 50, popularity: 0.48),
            CampusArea(id: "four-lakes-market", name: "Four Lakes Market", shortName: "Four Lakes Market",
                       category: .dining, coordinate: Coordinate(43.0763, -89.4183), radiusMeters: 55, popularity: 0.58),
            CampusArea(id: "camp-randall", name: "Camp Randall Stadium", shortName: "Camp Randall",
                       category: .athletics, coordinate: Coordinate(43.0699, -89.4127), radiusMeters: 90, popularity: 0.3),
        ],
        participationScale: 1.0,
        isPilot: false
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
        isPilot: false
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
        isPilot: true
    )

    static let all: [Campus] = [madison, michigan, stanford]

    static func campus(withID id: String) -> Campus? {
        all.first { $0.id == id }
    }
}
