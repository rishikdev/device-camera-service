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
/// This initialiser utilises action injection to elegantly separate the hardware matrix maths
/// from the UI layer. When the user taps the camera preview, the underlying UIKit coordinator
/// calculates both the screen position and the normalised sensor position, routing them directly
/// to their respective closures.
/// 
/// - Parameters:
///   - session: The active `AVCaptureSession` coordinating the optical hardware.
///   - executeHardwareFocus: An optional closure providing the normalised camera coordinate
///     (ranging strictly from 0.0 to 1.0). Use this to command the physical lens to focus.
///   - updateUIFocusBox: An optional closure providing the absolute screen coordinate
///     (in view points). Use this to safely render and animate your SwiftUI focus indicators.
///     
public struct DeviceCameraPreview: UIViewRepresentable {
    
    public let session: AVCaptureSession
    public var executeHardwareFocus: ((CGPoint) -> Void)?
    public var updateUIFocusBox: ((CGPoint) -> Void)?
    
    public init(
        session: AVCaptureSession,
        executeHardwareFocus: ((CGPoint) -> Void)? = nil,
        updateUIFocusBox: ((CGPoint) -> Void)? = nil
    ) {
        self.session = session
        self.executeHardwareFocus = executeHardwareFocus
        self.updateUIFocusBox = updateUIFocusBox
    }
    
    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        // Attach a native UIKit tap gesture so we can access the layer's maths functions
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
        var parent: DeviceCameraPreview
        
        init(_ parent: DeviceCameraPreview) {
            self.parent = parent
        }
        
        @objc func handleTap(_ sender: UITapGestureRecognizer) {
            guard let view = sender.view as? PreviewView else { return }
            
            let viewPoint = sender.location(in: view)
            let cameraPoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
            
            // The preview routes the data exactly where it needs to go
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
