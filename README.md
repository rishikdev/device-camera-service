# DeviceCameraService

A declarative Swift package that streamlines iOS camera integration. Integrate the device's camera into your application with minimal boilerplate.

Built for modern iOS development, this package handles the complex matrix math and hardware lifecycle management of `AVFoundation` behind a strictly isolated, Swift 6 concurrency-safe interface.

## Features

* **Virtual Lens Abstraction:** Automatically maps the active device's physical lenses (Ultra Wide, Wide, Telephoto) into a seamless, cycleable UI array.
* **Magnetic Pinch-to-Zoom:** Implements OEM-style "phantom tracking" and magnetic snap thresholds for perfectly smooth zooming and optical lens switching.
* **Precision Focus Mapping:** `CameraPreview` handles all `AVCaptureVideoPreviewLayer` coordinate conversions internally, safely exposing standard view coordinates for UI animations.
* **API Parity:** Designed to be used in tandem with [`SimulatorCameraService`](https://github.com/rishikdev/simulator-camera-service.git). Both packages share identical class names, properties, and method signatures, allowing you to drop compiler directives (`#if targetEnvironment`) from your view body.
* **Swift 6 Strict Concurrency:** Fully `@MainActor` isolated, utilising `@unchecked Sendable` boundaries for thread-safe background hardware execution.

## Installation

Add this package to your project using Swift Package Manager.

In Xcode:
1. Go to **File** > **Add Package Dependencies...**
2. Enter the repository URL: `https://github.com/rishikdev/device-camera-service.git`
3. Choose the dependency rule (e.g., Up to Next Major Version).

## Quick Start

Here is a simple example of how to implement `DeviceCameraService` in a SwiftUI view. Note the use of `.onDisappear` for safe hardware teardown.

```swift
import SwiftUI
import DeviceCameraService

struct SimpleCameraView: View {
    
    @State private var camera = CameraService()
    
    var body: some View {
        ZStack {
            // 1. The Declarative Camera Preview
            CameraPreview(
                service: camera,
                executeHardwareFocus: { cameraPoint in
                    try? camera.focus(at: cameraPoint)
                },
                updateUIFocusBox: { viewPoint in
                    print("Animate focus box at: \(viewPoint)")
                }
            )
            .ignoresSafeArea()
            .gesture(
                MagnifyGesture()
                    .onChanged { value in try? camera.zoom(with: value.magnification) }
            )
            
            // 2. UI Controls
            VStack {
                Spacer()
                HStack {
                    Button("Switch Lens") { try? camera.cycleLens() }
                    Spacer()
                    Button("Capture") { camera.takePhoto() }
                }
                .padding()
                .background(.black.opacity(0.5))
            }
        }
        .task {
            // Spin up the hardware safely
            try? await camera.startCamera()
        }
        .onDisappear {
            // Gracefully release hardware locks when view is hidden
            camera.stopCamera()
        }
    }
}
