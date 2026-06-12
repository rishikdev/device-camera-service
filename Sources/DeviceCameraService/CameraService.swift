// The Swift Programming Language
// https://docs.swift.org/swift-book

import AVFoundation
import SwiftUI
import UIKit

/// A hardware-accelerated service responsible for managing physical iOS camera devices.
/// Handles virtual lens abstraction, automatic focus coordination, and thread-safe session execution.
@MainActor
@Observable
public class CameraService: NSObject {
    
    /// The underlying AVFoundation pipeline coordinating the hardware.
    public let session = AVCaptureSession()
    
    /// The most recently captured full-resolution image.
    public var capturedImage: UIImage? = nil
    
    /// A dynamically generated array of optical lenses available on the current physical device.
    public private(set) var availableLenses: [VirtualLens] = []
    
    /// The currently active optical lens.
    public var activeLens: VirtualLens?
    
    /// The flash mode applied to the next photo capture.
    public var flashMode: CameraFlashMode = .auto
    
    /// The current exact hardware zoom multiplier.
    public var currentZoomFactor: CGFloat = 1.0
    
    /// The hardware zoom multiplier that corresponds to the standard "1x" wide lens.
    public private(set) var baseZoomFactor: CGFloat = 1.0
    
    private var gestureZoomFactor: CGFloat = 1.0
    private var absoluteMaxZoom: CGFloat = 10.0
    
    private var videoInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var currentPosition: AVCaptureDevice.Position = .back
    
    public override init() { super.init() }
    
    /// Requests user permissions and configures the physical hardware session.
    /// - Throws: `CameraError` if permissions are denied or hardware cannot be locked.
    public func startCamera() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw CameraError.permissionDenied }
        } else if status != .authorized {
            throw CameraError.permissionDenied
        }
        
        try configureSession()
    }
    
    /// Safely powers down the camera hardware and releases background threads.
    /// This should be called when the camera view disappears to preserve battery.
    public func stopCamera() {
        final class SessionContainer: @unchecked Sendable {
            let session: AVCaptureSession
            init(_ session: AVCaptureSession) { self.session = session }
        }
        
        let container = SessionContainer(self.session)
        Task.detached {
            if container.session.isRunning {
                container.session.stopRunning()
            }
        }
    }
    
    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        
        if let currentInput = self.videoInput {
            session.removeInput(currentInput)
        }
        
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
    
    private func findBestCamera(for position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        if position == .front {
            guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                throw CameraError.deviceUnavailable
            }
            return front
        }
        
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
        guard let bestDevice = discovery.devices.first else {
            throw CameraError.deviceUnavailable
        }
        return bestDevice
    }
    
    private func mapVirtualLenses(for device: AVCaptureDevice) {
        var lenses: [VirtualLens] = []
        
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
            lenses.append(VirtualLens(name: "0.5x", zoomFactor: 1.0))
            let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors
            if switchovers.count > 0 {
                lenses.append(VirtualLens(name: "1x", zoomFactor: CGFloat(switchovers[0].floatValue)))
            }
            if switchovers.count > 1 {
                let teleRatio = Int(round(switchovers[1].floatValue / switchovers[0].floatValue))
                lenses.append(VirtualLens(name: "\(teleRatio)x", zoomFactor: CGFloat(switchovers[1].floatValue)))
            }
        } else if device.deviceType == .builtInDualCamera {
            lenses.append(VirtualLens(name: "1x", zoomFactor: 1.0))
            let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors
            if switchovers.count > 0 {
                let teleRatio = Int(round(switchovers[0].floatValue))
                lenses.append(VirtualLens(name: "\(teleRatio)x", zoomFactor: CGFloat(switchovers[0].floatValue)))
            }
        } else {
            lenses.append(VirtualLens(name: "1x", zoomFactor: 1.0))
        }
        
        self.availableLenses = lenses
        let default1x = lenses.first(where: { $0.name == "1x" }) ?? lenses.first
        self.baseZoomFactor = default1x?.zoomFactor ?? 1.0
        
        self.activeLens = default1x
        self.currentZoomFactor = self.baseZoomFactor
        self.gestureZoomFactor = self.baseZoomFactor
        
        let oemMaxUserZoom: CGFloat = 5.0
        self.absoluteMaxZoom = min(oemMaxUserZoom * self.baseZoomFactor, device.activeFormat.videoMaxZoomFactor)
        
        try? setHardwareZoom(to: self.currentZoomFactor)
    }
    
    /// Triggers the active hardware to capture a high-resolution photo.
    public func takePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(flashMode.avFlashMode) {
            settings.flashMode = flashMode.avFlashMode
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    /// Cycles the current flash mode (Auto -> On -> Off).
    public func toggleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        case .off: flashMode = .auto
        }
    }
    
    /// Toggles the hardware session between the front and rear camera modules.
    public func switchCamera() throws {
        currentPosition = currentPosition == .back ? .front : .back
        try configureSession()
    }
    
    /// Seamlessly jumps to the next available physical optical lens.
    public func cycleLens() throws {
        guard availableLenses.count > 1, let active = activeLens, let currentIndex = availableLenses.firstIndex(of: active) else { return }
        let nextIndex = (currentIndex + 1) % availableLenses.count
        let nextLens = availableLenses[nextIndex]
        self.gestureZoomFactor = nextLens.zoomFactor
        try setHardwareZoom(to: nextLens.zoomFactor)
    }
    
    /// Applies a continuous digital zoom delta, factoring in magnetic snap physics for optical thresholds.
    /// - Parameter factor: The pinch magnification delta to apply.
    public func zoom(with factor: CGFloat) throws {
        gestureZoomFactor = max(1.0, min(gestureZoomFactor * factor, absoluteMaxZoom))
        var hardwareZoomToApply = gestureZoomFactor
        
        for lens in availableLenses {
            let lowerBound = lens.zoomFactor * 0.97
            let upperBound = lens.zoomFactor * 1.03
            if gestureZoomFactor >= lowerBound && gestureZoomFactor <= upperBound {
                hardwareZoomToApply = lens.zoomFactor
                break
            }
        }
        try setHardwareZoom(to: hardwareZoomToApply)
    }
    
    private func setHardwareZoom(to factor: CGFloat) throws {
        guard let device = videoInput?.device else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            currentZoomFactor = factor
            if let matchedLens = availableLenses.last(where: { factor >= $0.zoomFactor }) {
                activeLens = matchedLens
            }
            device.unlockForConfiguration()
        } catch {
            throw CameraError.configurationLockFailed(error.localizedDescription)
        }
    }
    
    /// Directs the physical optical lens to focus and expose on a specific sensor coordinate.
    /// - Parameter point: A normalised coordinate (0.0 to 1.0) relative to the sensor geometry.
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

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            Task { @MainActor [weak self] in self?.capturedImage = image }
        }
    }
}
