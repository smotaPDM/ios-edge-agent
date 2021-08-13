//
//  PharmaledgerMessageHandler.swift
//  PSKNodeServer
//  Created by Sergio Mota on 20/07/2021.
//  Based on file:
//  https://github.com/PharmaLedger-IMI/pharmaledger-camera/blob/feature/jscamera/WkCamera/WkCamera/JsMessageHandler.swift
//  JsMessageHandler.swift
//  jscamera
//
//  Created by Yves Delacrétaz on 29.06.21.
//  Updated from code @ 30.07.2021
//

import Foundation
import WebKit
import AVFoundation
import PharmaLedger_Camera
import Accelerate
import GCDWebServers

public enum MessageNames: String, CaseIterable {
    case StartCamera = "StartCamera"
    case StopCamera = "StopCamera"
    case TakePicture = "TakePicture"
    case SetFlashMode = "SetFlashMode"
    case GetAllSessionPresetStrings = "GetAllSessionPresetStrings"
}

enum StreamResponseError: Error {
    case cannotCreateCIImage
    case cannotCreateCGImage
    case cannotCreateFrameHeadersData
}


public class PharmaledgerMessageHandler: NSObject, CameraEventListener, WKScriptMessageHandler {
    // MARK: public vars
    public var cameraSession: CameraSession?
    public var cameraConfiguration: CameraConfiguration?
    // MARK: log vars
    private let logPreview = true;
    // const mthod to run inside the iframe from the leaflet app...
    private let jsWindowPrefix = "document.getElementsByTagName('iframe')[0].contentWindow.";
    
    // MARK: WKScriptMessageHandler
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("PharmaledgerMessageHandler - userContentController")
        var args: [String: AnyObject]? = nil
        var jsCallback: String? = nil
        if let messageName = MessageNames(rawValue: message.name) {
            if let bodyDict = message.body as? [String: AnyObject] {
                args = bodyDict["args"] as? [String: AnyObject]
                jsCallback = bodyDict["callback"] as? String
            }
            self.handleMessage(message: messageName, args: args, jsCallback: jsCallback, completion: {result in
                if let result = result {
                    print("result from js: \(result)")
                }
            })
        } else {
            print("Unrecognized message")
        }
    }
    
    // MARK: CameraEventListener
    public func onCameraPermissionDenied() {
        print("PharmaledgerMessageHandler - onCameraPermissionDenied denied")
    }
    
    private var dataBuffer_w = -1
    private var dataBuffer_h = -1
    private var dataBufferRGBA: UnsafeMutableRawPointer? = nil
    private var dataBufferRGB: UnsafeMutableRawPointer? = nil
    private var dataBufferRGBsmall: UnsafeMutableRawPointer? = nil
    private var rawData = Data()
    private var previewData = Data()
    private var currentCIImage: CIImage? = nil
    public func onPreviewFrame(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Cannot get imageBuffer")
            return
        }
        currentCIImage = CIImage(cvImageBuffer: imageBuffer, options: nil)
    }
    
    public func prepareRGBData(ciImage: CIImage, roi: CGRect?) -> Data {
        if(logPreview){
            print("PharmaledgerMessageHandler - prepareRGBData")
        }
        let extent: CGRect = roi ?? ciImage.extent
        let cgImage = ciContext.createCGImage(ciImage, from: extent)
        let colorspace = CGColorSpaceCreateDeviceRGB()
        let rowBytes = cgImage!.bytesPerRow
        let bpc = cgImage!.bitsPerComponent
        let w = cgImage!.width
        let h = cgImage!.height
        if w != dataBuffer_w || h != dataBuffer_h {
            if dataBufferRGBA != nil {
                free(dataBufferRGBA)
                dataBufferRGBA = nil
            }
            if dataBufferRGB != nil {
                free(dataBufferRGB)
                dataBufferRGB = nil
            }
        }
        if dataBufferRGBA == nil {
            dataBufferRGBA = malloc(rowBytes*h)
            dataBuffer_w = w
            dataBuffer_h = h
        }
        if dataBufferRGB == nil {
            dataBufferRGB = malloc(3*w*h)
        }
        let cgContext = CGContext(data: dataBufferRGBA, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: rowBytes, space: colorspace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        cgContext?.draw(cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        var inBuffer = vImage_Buffer(
            data: dataBufferRGBA!,
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: rowBytes)
        var outBuffer = vImage_Buffer(
            data: dataBufferRGB,
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: 3*w)
        vImageConvert_RGBA8888toRGB888(&inBuffer, &outBuffer, UInt32(kvImageNoFlags))
        
        let data = Data(bytesNoCopy: dataBufferRGB!, count: 3*w*h, deallocator: .none)
        return data
    }
    
    public func preparePreviewData(ciImage: CIImage) -> (Data, Int, Int) {
        if(logPreview){
            print("PharmaledgerMessageHandler - preparePreviewData")
        }
        let resizeFilter = CIFilter(name: "CILanczosScaleTransform")!
        resizeFilter.setValue(ciImage, forKey: kCIInputImageKey)
        let previewHeight = Int(CGFloat(ciImage.extent.height) / CGFloat(ciImage.extent.width) * CGFloat(self.previewWidth))
        let scale = CGFloat(previewHeight) / ciImage.extent.height
        let ratio = CGFloat(self.previewWidth) / CGFloat(ciImage.extent.width) / scale
        resizeFilter.setValue(scale, forKey: kCIInputScaleKey)
        resizeFilter.setValue(ratio, forKey: kCIInputAspectRatioKey)
        let ciImageRescaled = resizeFilter.outputImage!
        //
        let cgImage = ciContext.createCGImage(ciImageRescaled, from: ciImageRescaled.extent)
        let colorspace = CGColorSpaceCreateDeviceRGB()
        let bpc = cgImage!.bitsPerComponent
        let Bpr = cgImage!.bytesPerRow
        let cgContext = CGContext(data: nil, width: cgImage!.width, height: cgImage!.height, bitsPerComponent: bpc, bytesPerRow: Bpr, space: colorspace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)


        cgContext?.draw(cgImage!, in: CGRect(x: 0, y: 0, width: cgImage!.width, height: cgImage!.height))
        if dataBufferRGBsmall == nil {
            dataBufferRGBsmall = malloc(3*cgImage!.height*cgImage!.width)
        }
        var inBufferSmall = vImage_Buffer(
            data: cgContext!.data!,
            height: vImagePixelCount(cgImage!.height),
            width: vImagePixelCount(cgImage!.width),
            rowBytes: Bpr)
        var outBufferSmall = vImage_Buffer(
            data: dataBufferRGBsmall,
            height: vImagePixelCount(cgImage!.height),
            width: vImagePixelCount(cgImage!.width),
            rowBytes: 3*cgImage!.width)
        vImageConvert_RGBA8888toRGB888(&inBufferSmall, &outBufferSmall, UInt32(kvImageNoFlags))
        let data = Data(bytesNoCopy: dataBufferRGBsmall!, count: 3*cgImage!.width*cgImage!.height, deallocator: .none)
        return (data, self.previewWidth, previewHeight)
    }
    
    public func onCapture(imageData: Data) {
        print("PharmaledgerMessageHandler - onCapture")
        print("captureCallback")
//        if let image = UIImage.init(data: imageData){
//            print("image acquired \(image.size.width)x\(image.size.height)")
//        }
        if let jsCallback = self.onCaptureJsCallback {
            guard let webview = self.webview else {
                print("WebView was nil")
                return
            }
            let base64 = "data:image/jpeg;base64, " + imageData.base64EncodedString()
            let js = "\(jsWindowPrefix)\(jsCallback)(\"\(base64)\")"
            DispatchQueue.main.async {
                webview.evaluateJavaScript(js, completionHandler: {result, error in
                    guard error == nil else {
                        print(error!)
                        return
                    }
                })
            }
        }
    }
    
    public func onCameraInitialized() {
        print("PharmaledgerMessageHandler - onCameraInitialized")
        print("Camera initialized")
        DispatchQueue.main.async {
            self.callJsAfterCameraStart()
        }
    }
    
    // MARK: privates vars
    private var webview: WKWebView? = nil
    private var onGrabFrameJsCallBack: String?
    private let ciContext = CIContext(options: nil)
    private var previewWidth = 640;
    private var onCameraInitializedJsCallback: String?
    private var onCaptureJsCallback: String?
    let webserver = GCDWebServer()
    let mjpegQueue = DispatchQueue(label: "stream-queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    let rawframeQueue = DispatchQueue(label: "rawframe-queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    let previewframeQueue = DispatchQueue(label: "previewframe-queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    
    
    // MARK: public methods
    public override init() {
        super.init()
        addWebserverHandlers()
        startWebserver()
    }
    
    deinit {
        if let webview = webview {
            if let cameraSession = self.cameraSession {
                if let captureSession = cameraSession.captureSession {
                    if captureSession.isRunning {
                        cameraSession.stopCamera()
                    }
                }
                self.cameraSession = nil
            }
            for m in MessageNames.allCases {
                webview.configuration.userContentController.removeScriptMessageHandler(forName: m.rawValue)
            }
            self.webview = nil
            webserver.stop()
            webserver.removeAllHandlers()
        }
    }
    
    public func getWebview(frame: CGRect) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        // add all messages defined in MessageNames
        for m in MessageNames.allCases {
            configuration.userContentController.add(self, name: m.rawValue)
        }
        self.webview = WKWebView(frame: frame, configuration: configuration)
        return self.webview!
    }
    
    public func handleMessage(message: MessageNames, args: [String: AnyObject]? = nil, jsCallback: String? = nil, completion: ( (Any?) -> Void )? = nil) {
        guard let webview = self.webview else {
            print("WebView was nil")
            return
        }
        // string used as returned argument that can be passed back to js with the callback
        var jsonString: String = ""
        switch message {
        case .StartCamera:
            if let pWidth = args?["previewWidth"] as? Int {
                self.previewWidth = pWidth
            }
            handleCameraStart(onCameraInitializedJsCallback: args?["onInitializedJsCallback"] as? String,
                              sessionPreset: args?["sessionPreset"] as! String,
                              flash_mode: args?["flashMode"] as? String,
                              auto_orientation_enabled: args?["auto_orientation_enabled"] as? Bool)
            jsonString = ""
        case .StopCamera:
            handleCameraStop()
            jsonString = ""
        case .TakePicture:
            handleTakePicture(onCaptureJsCallback: args?["onCaptureJsCallback"] as? String)
        case .SetFlashMode:
            handleSetFlashMode(mode: args?["mode"] as? String)
        case .GetAllSessionPresetStrings:
            break
        }
        if let callback = jsCallback {
            if !callback.isEmpty {
                DispatchQueue.main.async {
                    let js = "\(self.jsWindowPrefix)\(callback)(\(jsonString))"
                    webview.evaluateJavaScript(js, completionHandler: {result, error in
                        guard error == nil else {
                            print(error!)
                            return
                        }
                        if let completion = completion {
                            completion(result)
                        }
                    })
                }
            }
        }
    }
    
    // MARK: private methods
    private func startWebserver() {
        let options: [String: Any] = [
            GCDWebServerOption_Port: findFreePort(),
            GCDWebServerOption_BindToLocalhost: true
        ]
        do {
            try self.webserver.start(options: options)
        } catch {
            print(error)
        }
    }
    
    private func addWebserverHandlers() {
        print("PharmaledgerMessageHandler - init - 1")
     
        let dirPath = Bundle.main.path(forResource: "nodejsProject", ofType: nil)
        webserver.addGETHandler(forBasePath: "/", directoryPath: dirPath!, indexFilename: nil, cacheAge: 0, allowRangeRequests: false)
        webserver.addHandler(forMethod: "GET", path: "/mjpeg", request: GCDWebServerRequest.classForCoder(), asyncProcessBlock: {(request, completion) in
            let response = GCDWebServerStreamedResponse(contentType: "multipart/x-mixed-replace; boundary=0123456789876543210", asyncStreamBlock: {completion in
                self.mjpegQueue.async {
                    if let ciImage = self.currentCIImage {
                        if let tempImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                            let image = UIImage(cgImage: tempImage)
                            let jpegData = image.jpegData(compressionQuality: 0.5)!
                            
                            let frameHeaders = [
                                "",
                                "--0123456789876543210",
                                "Content-Type: image/jpeg",
                                "Content-Length: \(jpegData.count)",
                                "",
                                ""
                            ]
                            if let frameHeadersData = frameHeaders.joined(separator: "\r\n").data(using: String.Encoding.utf8) {
                                var allData = Data()
                                allData.append(frameHeadersData)
                                allData.append(jpegData)
                                let footersData = ["", ""].joined(separator: "\r\n").data(using: String.Encoding.utf8)!
                                allData.append(footersData)
                                completion(allData, nil)
                            } else {
                                print("Could not make frame headers data")
                                completion(nil, StreamResponseError.cannotCreateFrameHeadersData)
                            }
                        } else {
                            completion(nil, StreamResponseError.cannotCreateCGImage)
                        }
                    } else {
                        completion(nil, StreamResponseError.cannotCreateCIImage)
                    }
                }
            })
            response.setValue("keep-alive", forAdditionalHeader: "Connection")
            response.setValue("0", forAdditionalHeader: "Ma-age")
            response.setValue("0", forAdditionalHeader: "Expires")
            response.setValue("no-store,must-revalidate", forAdditionalHeader: "Cache-Control")
            response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
            response.setValue("accept,content-type", forAdditionalHeader: "Access-Control-Allow-Headers")
            response.setValue("GET", forAdditionalHeader: "Access-Control-Allow-Methods")
            response.setValue("Cache-Control,Content-Encoding", forAdditionalHeader: "Access-Control-expose-headers")
            response.setValue("no-cache", forAdditionalHeader: "Pragma")
            completion(response)
        })
        
        webserver.addHandler(forMethod: "GET", path: "/rawframe", request: GCDWebServerRequest.classForCoder(), asyncProcessBlock: { (request, completion) in
            self.rawframeQueue.async {
                var roi: CGRect? = nil
                if let query = request.query {
                    if query.count > 0 {
                        guard let x = query["x"], let y = query["y"], let w = query["w"], let h = query["h"] else {
                            let response = GCDWebServerErrorResponse.init(text: "Must specify exactly 4 params (x, y, w, h) or none.")
                            response?.statusCode = 400
                            completion(response)
                            return
                        }
                        guard let x = Int(x), let y = Int(y), let w = Int(w), let h = Int(h) else {
                            let response = GCDWebServerErrorResponse.init(text: "(x, y, w, h) must be integers.")
                            response?.statusCode = 400
                            completion(response)
                            return
                        }
                        roi = CGRect(x: x, y: y, width: w, height: h)
                    }
                }
                if let ciImage = self.currentCIImage {
                    let data = self.prepareRGBData(ciImage: ciImage, roi: roi)
                    let contentType = "application/octet-stream"
                    let response = GCDWebServerDataResponse(data: data, contentType: contentType)
                    let imageSize: CGSize = roi?.size ?? ciImage.extent.size
                    response.setValue(String(Int(imageSize.width)), forAdditionalHeader: "image-width")
                    response.setValue(String(Int(imageSize.height)), forAdditionalHeader: "image-height")
                    completion(response)
                } else {
                    completion(GCDWebServerErrorResponse.init(statusCode: 500))
                }
            }
        })
        webserver.addHandler(forMethod: "GET", path: "/previewframe", request: GCDWebServerRequest.self, asyncProcessBlock: {(request, completion) in
            self.previewframeQueue.async {
                if let ciImage = self.currentCIImage {
                    let (data, w, h) = self.preparePreviewData(ciImage: ciImage)
                    let contentType = "application/octet-stream"
                    let response = GCDWebServerDataResponse(data: data, contentType: contentType)
                    response.setValue(String(w), forAdditionalHeader: "image-width")
                    response.setValue(String(h), forAdditionalHeader: "image-height")
                    completion(response)
                } else {
                    completion(GCDWebServerErrorResponse(statusCode: 500))
                }
            }
        })
        
        webserver.addHandler(forMethod: "GET", path: "/snapshot", request: GCDWebServerRequest.classForCoder(), asyncProcessBlock: {(request, completion) in
            DispatchQueue.global().async {
               if let camSession = self.cameraSession {
                    let semaphore = DispatchSemaphore(value: 0)
                    let photoSettings = AVCapturePhotoSettings()
                    photoSettings.isHighResolutionPhotoEnabled = true
                    photoSettings.flashMode = camSession.getConfig()!.getFlashMode()
                    var response: GCDWebServerResponse? = nil
                    let processor = CaptureProcessor(completion: {data in
                        let contentType = "image/jpeg"
                        response = GCDWebServerDataResponse(data: data, contentType: contentType)
                        semaphore.signal()
                    })
                    guard let photoOutput = camSession.getPhotoOutput() else {
                        completion(nil)
                        return
                    }
                    photoOutput.capturePhoto(with: photoSettings, delegate: processor)
                    _ = semaphore.wait(timeout: DispatchTime.now().advanced(by: DispatchTimeInterval.seconds(10)))
                    completion(response)
                }
            }
        })
    }
    
    
    private func handleCameraStart(onCameraInitializedJsCallback: String?, sessionPreset: String, flash_mode: String?, auto_orientation_enabled: Bool?) {
        self.onCameraInitializedJsCallback = onCameraInitializedJsCallback
        self.cameraConfiguration = .init(flash_mode: flash_mode, color_space: nil, session_preset: sessionPreset, auto_orienation_enabled: auto_orientation_enabled ?? false)
        self.cameraSession = .init(cameraEventListener: self, cameraConfiguration: self.cameraConfiguration!)
        return
    }
    
    private func handleCameraStop() {
        if let cameraSession = self.cameraSession {
            if let captureSession = cameraSession.captureSession {
                if captureSession.isRunning {
                    cameraSession.stopCamera()
                }
            }
        }
        self.cameraSession = nil
        if dataBufferRGBA != nil {
            free(dataBufferRGBA!)
            dataBufferRGBA = nil
        }
        if dataBufferRGB != nil {
            free(dataBufferRGB)
            dataBufferRGB = nil
        }
        if dataBufferRGBsmall != nil {
            free(dataBufferRGBsmall)
            dataBufferRGBsmall = nil
        }
        dataBuffer_w = -1
        dataBuffer_h = -1
    }
    
    private func handleTakePicture(onCaptureJsCallback: String?) {
        self.onCaptureJsCallback = onCaptureJsCallback
        self.cameraSession?.takePicture()
    }
    
    private func handleSetFlashMode(mode: String?) {
        guard let mode = mode, let cameraConfiguration = cameraConfiguration else {
            return
        }
        cameraConfiguration.setFlashConfiguration(flash_mode: mode)
    }
    
    private func callJsAfterCameraStart() {
        if let jsCallback = self.onCameraInitializedJsCallback {
            guard let webview = self.webview else {
                print("WebView was nil")
                return
            }
            let jsCMD = "\(self.jsWindowPrefix)\(jsCallback)(\(self.webserver.port))"
            print("callJsAfterCameraStart = \(jsCMD)")
            DispatchQueue.main.async {
                webview.evaluateJavaScript(jsCMD, completionHandler: {result, error in
                    guard error == nil else {
                        print(error!)
                        return
                    }
                })
            }
        }
    }
}
