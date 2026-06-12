//
//  CameraTypes.swift
//  DeviceCameraService
//
//  Created by Rishik Dev on 11/06/26.
//

import AVFoundation
import Foundation

/// Errors that can occur during camera configuration and execution.
public enum CameraError: LocalizedError {
    case permissionDenied
    case deviceUnavailable
    case configurationFailed
    case configurationLockFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera access was denied by the user."
        case .deviceUnavailable: return "Could not locate a valid camera device."
        case .configurationFailed: return "Failed to configure the camera input/output."
        case .configurationLockFailed(let reason): return "Failed to lock device hardware: \(reason)"
        }
    }
}

/// The flash mode for photo capture.
public enum CameraFlashMode {
    case off, on, auto
    
    public var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }
}

/// Represents a specific optical zoom milestone on a Virtual Device.
public struct VirtualLens: Equatable {
    /// The human-readable name of the lens (e.g., "0.5x", "1x", "3x").
    public let name: String
    /// The actual hardware multiplier mapping to this physical lens.
    public let zoomFactor: CGFloat
}
