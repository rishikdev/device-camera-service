// The Swift Programming Language
// https://docs.swift.org/swift-book

import AVFoundation
import SwiftUI
import UIKit

@MainActor
@Observable
public class DeviceCameraService: NSObject {
    
    public let session = AVCaptureSession()
    public var capturedImage: UIImage? = nil
    
    // Virtual Lens Tracking
    public private(set) var availableLenses: [VirtualLens] = []
    public var activeLens: VirtualLens?
    
    public var flashMode: CameraFlashMode = .auto
    public var currentZoomFactor: CGFloat = 1.0
    public private(set) var baseZoomFactor: CGFloat = 1.0
    private var gestureZoomFactor: CGFloat = 1.0
    private var absoluteMaxZoom: CGFloat = 10.0 // Clamped max for digital zoom
    
    private var videoInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var currentPosition: AVCaptureDevice.Position = .back
    
    public override init() { super.init() }
    
    public func requestPermissionsAndSetup() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw CameraError.permissionDenied }
        } else if status != .authorized {
            throw CameraError.permissionDenied
        }
        
        try configureSession()
    }
    
    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        if let currentInput = self.videoInput {
            session.removeInput(currentInput)
        }
        
        // 1. Find the best Virtual Device available for the requested position
        let device = try findBestCamera(for: currentPosition)
        
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            throw CameraError.deviceUnavailable
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
            self.videoInput = input
        } else {
            throw CameraError.configurationFailed
        }
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        // 2. Map the hardware's switchover milestones into UI buttons
        mapVirtualLenses(for: device)
        
        final class SessionContainer: @unchecked Sendable {
            let session: AVCaptureSession
            init(_ session: AVCaptureSession) { self.session = session }
        }
        
        let container = SessionContainer(self.session)
        Task.detached {
            if !container.session.isRunning { container.session.startRunning() }
        }
    }
    
    /// Finds the most advanced camera system available. Prioritises Virtual Devices.
    private func findBestCamera(for position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        if position == .front {
            guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                throw CameraError.deviceUnavailable
            }
            return front
        }
        
        // Look for Triple, then DualWide, then Dual, and fallback to Wide
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
        guard let bestDevice = discovery.devices.first else {
            throw CameraError.deviceUnavailable
        }
        return bestDevice
    }
    
    /// Translates the physical hardware milestones into `VirtualLens` buttons for the UI.
    private func mapVirtualLenses(for device: AVCaptureDevice) {
        var lenses: [VirtualLens] = []
        
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
            // Base zoom (1.0) corresponds to the Ultra Wide lens (0.5x equivalent)
            lenses.append(VirtualLens(name: "0.5x", zoomFactor: 1.0))
            
            let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors
            if switchovers.count > 0 {
                // First switchover is the Wide lens (1x equivalent)
                lenses.append(VirtualLens(name: "1x", zoomFactor: CGFloat(switchovers[0].floatValue)))
            }
            if switchovers.count > 1 {
                // Second switchover is the Telephoto lens (e.g., 3x or 5x equivalent)
                let teleRatio = Int(round(switchovers[1].floatValue / switchovers[0].floatValue))
                lenses.append(VirtualLens(name: "\(teleRatio)x", zoomFactor: CGFloat(switchovers[1].floatValue)))
            }
        } else if device.deviceType == .builtInDualCamera {
            // Base zoom (1.0) corresponds to the Wide lens (1x equivalent)
            lenses.append(VirtualLens(name: "1x", zoomFactor: 1.0))
            let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors
            if switchovers.count > 0 {
                let teleRatio = Int(round(switchovers[0].floatValue))
                lenses.append(VirtualLens(name: "\(teleRatio)x", zoomFactor: CGFloat(switchovers[0].floatValue)))
            }
        } else {
            // Single lens fallback
            lenses.append(VirtualLens(name: "1x", zoomFactor: 1.0))
        }
        
        self.availableLenses = lenses
        
        // Find the "1x" lens and set it as the mathematical baseline
        let default1x = lenses.first(where: { $0.name == "1x" }) ?? lenses.first
        self.baseZoomFactor = default1x?.zoomFactor ?? 1.0
        
        self.activeLens = default1x
        self.currentZoomFactor = self.baseZoomFactor
        self.gestureZoomFactor = self.baseZoomFactor
        
        // Capping digital zoom to 5x user zoom (Matching Apple's OEM Camera limit)
        let oemMaxUserZoom: CGFloat = 5.0
        self.absoluteMaxZoom = min(oemMaxUserZoom * self.baseZoomFactor, device.activeFormat.videoMaxZoomFactor)
        
        try? setHardwareZoom(to: self.currentZoomFactor)
    }
    
    // MARK: - Actions
    
    public func takePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(flashMode.avFlashMode) {
            settings.flashMode = flashMode.avFlashMode
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    public func toggleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        case .off: flashMode = .auto
        }
    }
    
    public func switchCamera() throws {
        currentPosition = currentPosition == .back ? .front : .back
        try configureSession()
    }
    
    /// Seamlessly loops through the available optical lenses.
    public func cycleLens() throws {
        guard availableLenses.count > 1, let active = activeLens, let currentIndex = availableLenses.firstIndex(of: active) else { return }
        
        let nextIndex = (currentIndex + 1) % availableLenses.count
        let nextLens = availableLenses[nextIndex]
        
        self.gestureZoomFactor = nextLens.zoomFactor
        
        // Instead of tearing down the session, we just change the zoom factor!
        try setHardwareZoom(to: nextLens.zoomFactor)
    }
    
    /// Adjusts the global zoom factor and automatically switches lenses behind the scenes.
    public func zoom(with factor: CGFloat) throws {
        // 1. Apply the maths to the phantom tracker, NOT the hardware state
        gestureZoomFactor = max(1.0, min(gestureZoomFactor * factor, absoluteMaxZoom))
        
        var hardwareZoomToApply = gestureZoomFactor
        
        // 2. See if the phantom tracker is hovering near a physical lens
        for lens in availableLenses {
            let lowerBound = lens.zoomFactor * 0.97 // 3% snap window
            let upperBound = lens.zoomFactor * 1.03
            
            if gestureZoomFactor >= lowerBound && gestureZoomFactor <= upperBound {
                hardwareZoomToApply = lens.zoomFactor
                break
            }
        }
        
        // 3. Send the calculated value to the camera
        try setHardwareZoom(to: hardwareZoomToApply)
    }
    
    /// Helper to apply zoom and update the UI string based on the current threshold.
    private func setHardwareZoom(to factor: CGFloat) throws {
        guard let device = videoInput?.device else { return }
        
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            currentZoomFactor = factor
            
            // Automatically highlight the correct UI button (e.g., changes from 1x to 3x mid-pinch)
            if let matchedLens = availableLenses.last(where: { factor >= $0.zoomFactor }) {
                activeLens = matchedLens
            }
            
            device.unlockForConfiguration()
        } catch {
            throw CameraError.configurationLockFailed(error.localizedDescription)
        }
    }
    
    public func focus(at point: CGPoint) throws {
        guard let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        } catch {
            throw CameraError.configurationLockFailed(error.localizedDescription)
        }
    }
}

extension DeviceCameraService: AVCapturePhotoCaptureDelegate {
    nonisolated public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            Task { @MainActor [weak self] in self?.capturedImage = image }
        }
    }
}
