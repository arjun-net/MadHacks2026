import Foundation

/// One reading from the server: where someone was, and the building the server matched it to.
///
/// The app never works out buildings from coordinates itself. The server tags each ping with
/// its building when it's stored (see the backend's building grid) and returns that tag here.
struct Reading: Hashable, Sendable {
    let coordinate: Coordinate
    /// The server's building for this reading (its name, or its id in older rows), or nil.
    var building: String? = nil
}
