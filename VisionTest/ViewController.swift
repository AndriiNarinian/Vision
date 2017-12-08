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

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {

    @IBOutlet private weak var cameraView: UIView?
    @IBOutlet private weak var previewView: UIView?
    @IBOutlet private weak var previewImageView: UIImageView?
    @IBOutlet private weak var classificationLabel: UILabel?
    @IBOutlet private weak var rectLocatorView: UIView?
    
    private var dimensions = CMVideoDimensions()
    private var lastCIImage: CIImage?
    private var textLayer: CATextLayer! = nil
    private var rootLayer: CALayer! = nil
    private var detectionOverlay: CALayer! = nil
    private var requests = [VNRequest]()
    private var perspectiveDetectionRequest: VNDetectRectanglesRequest!
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
        
        // make the camera appear on the screen
        self.cameraView?.layer.addSublayer(self.cameraLayer)
        
        // register to receive buffers from the camera
        let videoOutput = AVCaptureVideoDataOutput()
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "MyQueue"))
        self.captureSession.addOutput(videoOutput)

        self.captureSession.startRunning()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // make sure the layer is the correct size
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
        rectangleDetectionRequest.maximumObservations = 20
        
        perspectiveDetectionRequest = VNDetectRectanglesRequest(completionHandler: self.handlePerspective)
        perspectiveDetectionRequest.minimumSize = 0.1
        perspectiveDetectionRequest.maximumObservations = 20
        
        //let url = URL(string: "https://ae01.alicdn.com/kf/HTB1hHC9MVXXXXcfXVXXq6xXFXXXW/-font-b-Mona-b-font-font-b-Lisa-b-font-Famous-Oil-font-b-Paintings.jpg")!
        let cgImage = #imageLiteral(resourceName: "mona").cgImage!
        rectLocatorView?.frame = cameraView?.frame ?? rectLocatorView?.frame ?? .zero
        
        let translationalImageRegistrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: cgImage, options: [:]) { (request, error) in
            guard let transform = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform else { return }
            DispatchQueue.main.async {
                //self.rectLocatorView?.transform = transform
                let tx = transform.tx
                let ty = transform.ty
                self.classificationLabel?.text = ["\(tx)", "\(ty)"].joined(separator: "\n")
            }
        }
        
        let homographicImageRegistrationRequest = VNHomographicImageRegistrationRequest(targetedCGImage: cgImage, options: [:]) { (request, error) in
            guard let warpTransform = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { return }
            DispatchQueue.main.async {
                let first = warpTransform.columns.0
                let second = warpTransform.columns.1
                let third = warpTransform.columns.2
                
                let fX = first.x; let fY = first.y; let fZ = first.z
                let sX = second.x; let sY = second.y; let sZ = second.z
                let tX = third.x; let tY = third.y; let tZ = third.z
                
                let text = ["\(fX)", "\(fY)", "\(fZ)", "\(sX)", "\(sY)", "\(sZ)", "\(tX)", "\(tY)", "\(tZ)"].joined(separator: "\n")

                self.classificationLabel?.text = text
            }
        }
        
        self.requests = [
            rectangleDetectionRequest,
            classificationRequest,
            translationalImageRegistrationRequest//,
            //homographicImageRegistrationRequest
        ]
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
    
    func handlePerspective(request: VNRequest, error: Error?) {
        DispatchQueue.main.async {
            guard let rectangleObservations = request.results as? [VNRectangleObservation] else { return }
            self.drawVisionPerspectiveRequestResults(rectangleObservations)
        }
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
            
            let rectangleDetectionRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .rightMirrored, options: requestOptions)
            try rectangleDetectionRequestHandler.perform([self.perspectiveDetectionRequest])
            
        } catch {
            print(error)
        }
        
    }

    func drawVisionPerspectiveRequestResults(_ results: [VNRectangleObservation]) {
        guard let selectedRect = results.first else { return }
        
        let horizontalFix = (cameraLayer.bounds.width - videoFrameSize.width)/2
        let points = [selectedRect.topLeft, selectedRect.topRight, selectedRect.bottomRight, selectedRect.bottomLeft]
        let convertedPoints = points.map { point -> CGPoint in
            let scaledPoint = point.scaled(to: videoFrameSize)
            
            return CGPoint(x: scaledPoint.x + horizontalFix, y: scaledPoint.y)
        }
        drawPolygon(convertedPoints, color: .red)
        let origin = (cameraView?.frame.origin)!
        let boundingBox = selectedRect.boundingBox.scaled(to: videoFrameSize)
        let boundingFrame = CGRect(x: boundingBox.origin.x + horizontalFix + origin.x, y: boundingBox.origin.y + origin.y, width: boundingBox.width, height: boundingBox.height)
        rectLocatorView?.frame = boundingFrame
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
        
    func convertPoint(_ point: CGPoint) -> CGPoint {
        let horizontalFix = (cameraLayer.frame.width - videoFrameSize.width)/2
        let converted = CGPoint(x: point.x * -videoFrameSize.width + horizontalFix, y: -point.y * videoFrameSize.height)
        
        return converted
    }
    
    func convertRect(_ rect: CGRect) -> CGRect {
        let horizontalFix = (cameraLayer.frame.width - videoFrameSize.width)/2
        let x = rect.origin.x * videoFrameSize.width + horizontalFix
        let y = rect.origin.y * videoFrameSize.height
        let width = rect.width * videoFrameSize.width
        let height = rect.height * videoFrameSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

extension ViewController {
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        
        rectLocatorView?.transform = .identity
    }
}

