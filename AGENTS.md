# Repository Guidelines

## Project Structure & Module Organization

- `Sources/` contains the native Swift application. `App.swift` starts AppKit; `ViewerModel.swift` owns shared state. DICOM/Xelis import, reformat geometry, planning, SwiftUI controls, and Metal rendering live in separate files.
- `Tests/main.swift` contains the executable regression suite and synthetic DICOM fixtures.
- `scripts/` contains build and test entry points. `tools/` holds the panoramic scale audit and comparison fixtures.
- `output/` holds ignored bundles, executables, caches, and reports. The sample study is also ignored. Icons use system symbols.
- Consult `README.md`, `CANAL-MANDIBULAR.md`, and `AUDITORIA-ESCALA-PANORAMICA.md` before changing import or measurement behavior.

## Build, Test, and Development Commands

Use macOS 13+, Xcode command-line tools, and a Metal-compatible GPU. Run from the repository root:

```sh
bash scripts/build.sh
bash scripts/test.sh
bash scripts/test.sh "/ruta/al/estudio-privado"
open output/DentalViewer.app
```

The build invokes `swiftc` in Swift 5 mode and creates an ad-hoc signed application. Tests exclude the application entry point; a study path enables real-study import and geometry checks. Open the bundle to verify interaction and rendering. No Swift Package Manager or Xcode project is configured.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` for types/files, and `lowerCamelCase` for members. Match nearby Swift formatting and keep geometry helpers separate from view interaction. Preserve Spanish user-facing labels. Use explicit coordinate spaces and millimeter units; validate finite values and bounds before drawing or importing. No formatter or linter is configured.

## Testing Guidelines

The suite uses custom `expect`/`expectThrows` assertions, not XCTest. Add descriptive failure messages and meaningful regressions to `Tests/main.swift`. Cover changed geometry, malformed input, and interaction state where relevant; no numerical coverage target exists. Run study-enabled tests for Xelis changes. If CLI Metal checks cannot run, verify rendering in the app and report that limitation. Exercise resizing and expanded panels for UI changes.

## Commit & Pull Request Guidelines

This checkout has no Git history, so no existing commit convention can be established. Use concise imperative summaries. PRs should explain the problem, resulting behavior, validation commands/results, and remaining limitations; link relevant issues and include UI screenshots when useful. Update affected documentation.

## Data & Runtime Constraints

Keep original studies read-only. Never commit patient data, study files, or identifiable screenshots. Do not add Docker, AI models, or inferred canal positions. Preserve imported Xelis coordinates and distinguish manual planning from original geometry. Save user planning before restarting a live session; describe measurement evidence without claiming clinical validation.
