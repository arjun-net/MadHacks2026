# MadHacks2026: Campus Pulse

A SwiftUI iOS app that shows a real-time, privacy-preserving heatmap of student activity across campus.

## Run
Open `CampusPulse.xcodeproj` in Xcode 26+, pick an iPhone simulator, and run. Targets iOS 17+, no third-party dependencies.

## Scope
UI only. There is no backend, no networking, and no location collection (no CoreLocation, no permission prompts).
All screens run on generated sample data (`SampleData/SampleActivityData.swift`), and the sharing toggle and permission status are local UI state (`State/SharingState.swift`).

Debug launch argument `-screen activity|settings|sharing|panel|denied` opens a specific screen or state.

## Structure
```
CampusPulse/
  App/            Entry point, RootView (tabs), AppContainer, AppConfig
  DesignSystem/   Theme tokens, glass/card modifiers, formatting
  Models/         Campus, CampusArea, CampusSnapshot, DensityCell, ActivityLevel, CampusCatalog
  SampleData/     Sample heat cells and area stats for the UI
  State/          CampusStore (selected campus + snapshot), SharingState, AppPreferences
  Heatmap/        HeatPalette, HeatmapGrid (Gaussian blur → image), map overlay renderer,
                  animator, CampusMapView (MKMapView bridge), building labels
  ViewModels/     Map, Activity, LocationSharing, Settings (MVVM, @Observable)
  Components/     Gauges, sparklines, bars, badges, floating tab bar, state views
  Views/          Map, Activity, Sharing, Settings screens
  Preview Content/PreviewData fixtures
```

## Privacy design (reflected in the UI)
- The map shows only combined density, never individual students.
- Spots with fewer than 5 students are left off the map; small counts appear as "Fewer than 10".
- Sharing is opt-in and off by default.
