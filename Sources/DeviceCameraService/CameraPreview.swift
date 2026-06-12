//
//  DeviceCameraPreview.swift
//  DeviceCameraService
//
//  Created by Rishik Dev on 11/06/26.
//

import AVFoundation
import SwiftUI

/// Initialises a declarative SwiftUI view that renders the live hardware camera feed.
/// 
/// This initialiser utilises action injection to elegantly separate the hardware matrix math
/// from the UI layer. When the user taps the camera preview, the underlying UIKit coordinator
/// calculates both the screen position and the normalised sensor position, routing them directly
/// to their respective closures.
public struct CameraPreview: UIViewRepresentable {
    
    public let session: AVCaptureSession
    public var executeHardwareFocus: ((CGPoint) -> Void)?
    public var updateUIFocusBox: ((CGPoint) -> Void)?
    
    /// Creates a hardware-accelerated preview rendering the active camera feed.
    /// - Parameters:
    ///   - service: The active `CameraService` coordinating the optical hardware.
    ///   - executeHardwareFocus: An optional closure providing the normalised camera coordinate (0.0 to 1.0).
    ///   - updateUIFocusBox: An optional closure providing the absolute screen coordinate (in view points).
    public init(
        service: CameraService,
        executeHardwareFocus: ((CGPoint) -> Void)? = nil,
        updateUIFocusBox: ((CGPoint) -> Void)? = nil
    ) {
        self.session = service.session
        self.executeHardwareFocus = executeHardwareFocus
        self.updateUIFocusBox = updateUIFocusBox
    }
    
    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        return view
    }
    
    public func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    public class Coordinator: NSObject {
        var parent: CameraPreview
        
        init(_ parent: CameraPreview) {
            self.parent = parent
        }
        
        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            guard let view = sender.view as? PreviewView else { return }
            let viewPoint = sender.location(in: view)
            let cameraPoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            parent.executeHardwareFocus?(cameraPoint)
            parent.updateUIFocusBox?(viewPoint)
        }
    }
    
    public class PreviewView: UIView {
        public override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
}
