//
//  ViewController.swift
//  VisionTest
//
//  Created by Andrii on 12/7/17.
//  Copyright © 2017 ROLIQUE. All rights reserved.
//

import UIKit
import AVFoundation
import Vision

//let url = URL(string: "https://ae01.alicdn.com/kf/HTB1hHC9MVXXXXcfXVXXq6xXFXXXW/-font-b-Mona-b-font-font-b-Lisa-b-font-Famous-Oil-font-b-Paintings.jpg")!

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    @IBOutlet private weak var cameraView: UIView?
    @IBOutlet private weak var previewView: UIView?
    @IBOutlet private weak var previewImageView: UIImageView?
    @IBOutlet private weak var sampleImageView: UIImageView?
    @IBOutlet private weak var classificationLabel: UILabel?
    @IBOutlet private weak var rectLocatorView: UIView?
    
    private var currentTargetRect: VNRectangleObservation?
    private var isAllowedToActivateRectangleDetection = false
    private var mySwitch = false
    private var dimensions = CMVideoDimensions()
    private var lastCIImage: CIImage?
    private var textLayer: CATextLayer! = nil
    private var rootLayer: CALayer! = nil
    private var detectionOverlay: CALayer! = nil
    private var requests = [VNRequest]()
    private var followRequest: VNTrackRectangleRequest!
    private var perspectiveDetectionRequest: VNDetectRectanglesRequest!
    private var homographicImageRegistrationRequest: VNHomographicImageRegistrationRequest!
    private var translationalImageRegistrationRequest: VNTranslationalImageRegistrationRequest!
    private lazy var cameraLayer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
    private lazy var detectedRectangleLayer: CAShapeLayer = {
        return CAShapeLayer()
    }()
    private lazy var captureSession: AVCaptureSession = {
        let session = AVCaptureSession()
        session.sessionPreset = AVCaptureSession.Preset.photo
        guard
            let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: backCamera)
            else { return session }
        session.addInput(input)
        self.dimensions = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        
        return session
    }()
    private var videoFrameSize: CGSize {
        let size = CGSize.aspectFit(aspectRatio: CGSize(width: Int(dimensions.height), height: Int(dimensions.width)), boundingSize: cameraLayer.bounds.size)

        return size
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupVision()
        
        self.cameraView?.layer.addSublayer(self.cameraLayer)
        
        let videoOutput = AVCaptureVideoDataOutput()
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "MyQueue"))
        self.captureSession.addOutput(videoOutput)

        self.captureSession.startRunning()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        self.cameraLayer.frame = self.cameraView?.bounds ?? .zero
        self.detectedRectangleLayer.frame = self.cameraLayer.frame
    }
    
    func setupVision() {
        guard let visionModel = try? VNCoreMLModel(for: Inceptionv3().model) else {
            fatalError("can't load vision ML model")
        }
        let classificationRequest = VNCoreMLRequest(model: visionModel, completionHandler: handleClassifications)
        classificationRequest.imageCropAndScaleOption = .centerCrop
        
        let rectangleDetectionRequest = VNDetectRectanglesRequest(completionHandler: self.handleRectangles)
        rectangleDetectionRequest.minimumSize = 0.1
        rectangleDetectionRequest.maximumObservations = 1
        
        perspectiveDetectionRequest = VNDetectRectanglesRequest(completionHandler: self.handlePerspective1)
        perspectiveDetectionRequest.minimumSize = 0.1
        perspectiveDetectionRequest.maximumObservations = 1
        
        let cgImage = (sampleImageView?.image?.cgImage)!
        
        rectLocatorView?.frame = cameraView?.frame ?? rectLocatorView?.frame ?? .zero
        
        translationalImageRegistrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: cgImage, options: [:], completionHandler: handleTranslationalImageRegistrationRequestCompletionHandler)
        
        homographicImageRegistrationRequest = VNHomographicImageRegistrationRequest(targetedCGImage: cgImage, options: [:], completionHandler: handleHomographicImageRegistrationRequestCompletionHandler)
        
        self.requests = [
            rectangleDetectionRequest
//            classificationRequest
        ]
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        var requestOptions: [VNImageOption: Any] = [:]
        if let cameraIntrinsicData = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, nil) {
            requestOptions = [.cameraIntrinsics: cameraIntrinsicData]
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        self.lastCIImage = ciImage.oriented(forExifOrientation: Int32(CGImagePropertyOrientation.up.rawValue))
        
        do {
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: requestOptions)
            try imageRequestHandler.perform(self.requests)
            
            //            if isAllowedToActivateRectangleDetection {
            //                isAllowedToActivateRectangleDetection = false
            let rectangleDetectionRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .rightMirrored, options: requestOptions)
            try rectangleDetectionRequestHandler.perform([self.perspectiveDetectionRequest])
            //            }
            
            if let currentTargetRect = currentTargetRect {
                self.handleVisionPerspectiveRequestResults([currentTargetRect])
            }
        
//            let translationalImageRegistrationRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .left, options: requestOptions)
//            try translationalImageRegistrationRequestHandler
//                .perform([self.translationalImageRegistrationRequest])


//            let homographicImageRegistrationRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .rightMirrored, options: requestOptions)
//            try homographicImageRegistrationRequestHandler.perform([self.homographicImageRegistrationRequest])
            
        } catch {
            print(error)
        }
        
    }

    func handleVisionPerspectiveRequestResults(_ results: [VNRectangleObservation]) {
        guard let selectedRect = results.first, let lastCIImage = lastCIImage else { return }
        
        let followRequest = VNTrackRectangleRequest(rectangleObservation: selectedRect) { (request, error) in
            DispatchQueue.main.async {
                guard let rectangleObservations = request.results as? [VNRectangleObservation] else { return }
                
                self.drawVisionPerspectiveRequestResults(rectangleObservations)
            }
        }
        let handler = VNImageRequestHandler(ciImage: lastCIImage, orientation: .up, options: [:])
        do {
        try handler.perform([followRequest])
        } catch { print(error.localizedDescription) }
    }
    
    func drawVisionPerspectiveRequestResults(_ results: [VNRectangleObservation]) {
        guard let selectedRect = results.first else { return }
        
        let horizontalFix = (cameraLayer.bounds.width - videoFrameSize.width)/2
        let points = [selectedRect.topLeft, selectedRect.topRight, selectedRect.bottomRight, selectedRect.bottomLeft]
        let convertedPoints = points.map { point -> CGPoint in
            let scaledPoint = point.scaled(to: videoFrameSize)
            
            return CGPoint(x: scaledPoint.x + horizontalFix, y: scaledPoint.y)
        }
        
        let origin = (cameraView?.frame.origin)!
        let boundingBox = selectedRect.boundingBox.scaled(to: videoFrameSize)
        let boundingFrame = CGRect(x: boundingBox.origin.x + horizontalFix + origin.x, y: boundingBox.origin.y + origin.y, width: boundingBox.width, height: boundingBox.height)
        
        guard lastCIImage?.extent.contains(boundingBox) == true
            else { print("invalid detected rectangle"); return }
        
        drawPolygon(convertedPoints, color: .red)
        
        if mySwitch {
            rectLocatorView?.frame = boundingFrame
        }
    }
    
    func drawVisionRectangleRequestResults(_ results: [VNRectangleObservation]) {
        guard let selectedRect = results.first,
            let image = self.lastCIImage
            else { return }
        
        let imageSize = CGSize.aspectFit(aspectRatio: CGSize(width: cameraView?.frame.size.width ?? 0, height: cameraView?.frame.size.height ?? 0), boundingSize: image.extent.size)

        let topLeft = selectedRect.topLeft.scaled(to: imageSize)
        let topRight = selectedRect.topRight.scaled(to: imageSize)
        let bottomLeft = selectedRect.bottomLeft.scaled(to: imageSize)
        let bottomRight = selectedRect.bottomRight.scaled(to: imageSize)
        
        let correctedImage = image
            .applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": CIVector(cgPoint: topLeft),
                "inputTopRight": CIVector(cgPoint: topRight),
                "inputBottomLeft": CIVector(cgPoint: bottomLeft),
                "inputBottomRight": CIVector(cgPoint: bottomRight)
                ])
            .oriented(.right)

        let uiImage = UIImage(ciImage: correctedImage)
        self.previewImageView?.image = uiImage
    }
    
    func exifOrientationFromDeviceOrientation() -> CGImagePropertyOrientation {
        return .rightMirrored
    }
    
    private func drawPolygon(_ points: [CGPoint], color: UIColor) {
        detectedRectangleLayer.removeFromSuperlayer()
        detectedRectangleLayer.fillColor = UIColor.clear.cgColor
        detectedRectangleLayer.strokeColor = color.cgColor
        detectedRectangleLayer.lineWidth = 2
        
        let path = UIBezierPath()
        path.move(to: points.last!)
        points.forEach { path.addLine(to: $0) }
        
        detectedRectangleLayer.path = path.cgPath
        cameraView?.layer.addSublayer(detectedRectangleLayer)
    }
    
    func handleClassifications(request: VNRequest, error: Error?) {
        guard let observations = request.results else {
            fatalError("no results: \(error!.localizedDescription)")
        }
        let classifications = observations[0...4]// use up to top 4 results
            .flatMap({ $0 as? VNClassificationObservation })// ignore unexpected cases
            .filter({ $0.confidence > 0.3 })// skip low confidence classifications
            .map { self.textForClassification($0) }// extract displayable text
        
        DispatchQueue.main.async {
            let text = classifications.joined(separator: ", ")
            
            //self.classificationLabel?.text = text
        }
    }
    
    func textForClassification(_ observation: VNClassificationObservation) -> String {
        return observation.identifier
    }
    
    func handleRectangles(request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            guard let rectangleObservations = request.results as? [VNRectangleObservation] else { return }
            
            self.drawVisionRectangleRequestResults(rectangleObservations)
        }
    }
    
    func handlePerspective1(request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            guard let rectangleObservations = request.results as? [VNRectangleObservation] else { return }
//            if self.currentTargetRect == nil {
                self.currentTargetRect = rectangleObservations.first
//            }
            //self.handleVisionPerspectiveRequestResults(rectangleObservations)
        }
    }
    
    func handlePerspective2(request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            guard let rectangleObservations = request.results as? [VNRectangleObservation] else { return }

            self.drawVisionPerspectiveRequestResults(rectangleObservations)
        }
    }
    
    //VNRequestCompletionHandler = (VNRequest, Error?) -> Void
    func handleTranslationalImageRegistrationRequestCompletionHandler(request: VNRequest, error: Error?) {
        guard let transform = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform else { return }
        DispatchQueue.main.async {
            
            let transform = transform.scaledBy(x: 1, y: 1)
            
            self.sampleImageView?.transform = transform
            
            let tx = transform.tx
            let ty = transform.ty
            let ta = transform.a
            let tb = transform.b
            let tc = transform.c
            let td = transform.d
            
            //self.classificationLabel?.text = ["\(tx)", "\(ty)", "\(ta)", "\(tb)", "\(tc)", "\(td)"].joined(separator: "\n")
        }
    }
    
    func handleHomographicImageRegistrationRequestCompletionHandler(request: VNRequest, error: Error?) {
        guard let warpTransform = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { return }
        
        let first = warpTransform.columns.0
        let second = warpTransform.columns.1
        let third = warpTransform.columns.2
        
        let fX = first.x; let fY = first.y; let fZ = first.z
        let sX = second.x; let sY = second.y; let sZ = second.z
        let tX = third.x; let tY = third.y; let tZ = third.z
        
        let text = ["\(fX)", "\(fY)", "\(fZ)", "\(sX)", "\(sY)", "\(sZ)", "\(tX)", "\(tY)", "\(tZ)"].joined(separator: "\n")
        DispatchQueue.main.async {
            self.classificationLabel?.text = text
            //self.classificationLabel?.text = String(describing: (request.results?.first as? VNImageHomographicAlignmentObservation)?.confidence ?? 0)
        }
    }
}

extension ViewController {
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        rectLocatorView?.transform = .identity
        mySwitch = !mySwitch
        isAllowedToActivateRectangleDetection = true
        currentTargetRect = nil
    }
}

