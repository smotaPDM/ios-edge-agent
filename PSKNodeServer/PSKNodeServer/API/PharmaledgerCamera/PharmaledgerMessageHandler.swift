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
}

public class PharmaledgerMessageHandler: NSObject, CameraEventListener, WKScriptMessageHandler {
    // MARK: public vars
    public var cameraSession: CameraSession?
    public var cameraConfiguration: CameraConfiguration?
    // MARK: log vars
    private let logPreview = true;
    
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
        print("PharmaledgerMessageHandler - Permission denied")
    }
    
    private var dataBufferRGBA: UnsafeMutableRawPointer? = nil
    private var dataBufferRGB: UnsafeMutableRawPointer? = nil
    private var dataBufferRGBsmall: UnsafeMutableRawPointer? = nil
    private var rawData = Data()
    private var previewData = Data()
    
    public func onPreviewFrame(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Cannot get imageBuffer")
            return
        }
        self.rawData = prepareRGBData(imageBuffer: imageBuffer)
        self.previewData = preparePreviewData(imageBuffer: imageBuffer)
    }
    
    public func prepareRGBData(imageBuffer: CVImageBuffer) -> Data {
        if(logPreview){
            print("PharmaledgerMessageHandler - prepareRGBData")
        }
        let flag = CVPixelBufferLockFlags.readOnly
        CVPixelBufferLockBaseAddress(imageBuffer, flag)
        let  rowBytes = CVPixelBufferGetBytesPerRow(imageBuffer)
        let w = CVPixelBufferGetWidth(imageBuffer)
        let h = CVPixelBufferGetHeight(imageBuffer)
        let buf = CVPixelBufferGetBaseAddress(imageBuffer)!
        
        if dataBufferRGBA == nil {
            dataBufferRGBA = malloc(rowBytes*h)
        }
        if dataBufferRGB == nil {
            dataBufferRGB = malloc(3*w*h)
        }
        memcpy(dataBufferRGBA!, buf, rowBytes*h)
        CVPixelBufferUnlockBaseAddress(imageBuffer, flag)
        
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
        vImageConvert_BGRA8888toRGB888(&inBuffer, &outBuffer, UInt32(kvImageNoFlags))
        
        let data = Data(bytesNoCopy: dataBufferRGB!, count: 3*w*h, deallocator: .none)
        return data
    }
    
    public func preparePreviewData(imageBuffer: CVImageBuffer) -> Data {
        if(logPreview){
            print("PharmaledgerMessageHandler - preparePreviewData")
        }
        var ciImage: CIImage = .init(cvImageBuffer: imageBuffer)
        let resizeFilter = CIFilter(name: "CILanczosScaleTransform")!
        resizeFilter.setValue(ciImage, forKey: kCIInputImageKey)
        let scale = CGFloat(self.previewWidth) / CGFloat(CVPixelBufferGetWidth(imageBuffer))
        resizeFilter.setValue(scale, forKey: kCIInputScaleKey)
        ciImage = resizeFilter.outputImage!
        //
        let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
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
        return data
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
            let js = "document.getElementsByTagName('iframe')[0].contentWindow.\(jsCallback)(\"\(base64)\")"
            print("PharmaledgerMessageHandler-onCapture-js:\(js)")
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
    private let ciContext = CIContext()
    private var previewWidth = 640;
    private var onCameraInitializedJsCallback: String?
    private var onCaptureJsCallback: String?
    let webserver = GCDWebServer()
    
    
    // MARK: public methods
    public override init() {
        print("PharmaledgerMessageHandler - init - 1")
        super.init()
//        webserver.addDefaultHandler(forMethod: "OPTIONS", request: GCDWebServerRequest.classForCoder()) { (req) -> GCDWebServerResponse? in
//            let resp = GCDWebServerResponse().applyCORSHeaders()
//            return resp
//        }
        print("PharmaledgerMessageHandler - init - 2")
        let dirPath = Bundle.main.path(forResource: "nodejsProject", ofType: nil)
        webserver.addGETHandler(forBasePath: "/", directoryPath: dirPath!, indexFilename: nil, cacheAge: 0, allowRangeRequests: false)
        webserver.addHandler(forMethod: "GET",
                             path: "/rawframe",
                             request: GCDWebServerRequest.self,
                             processBlock: { request in
//                                let data = "Hello from GCDWebserver".data(using: .utf8)!
//                                let contentType = "text/html"
                                let data = self.rawData
                                let contentType = "application/octet-stream"
                                let response = GCDWebServerDataResponse(data: data, contentType: contentType)
                                return response
                             })
        webserver.addHandler(forMethod: "GET",
                             path: "/previewframe",
                             request: GCDWebServerRequest.self,
                             processBlock: { request in
//                                let data = "Hello from GCDWebserver".data(using: .utf8)!
//                                let contentType = "text/html"
                                let data = self.previewData
                                let contentType = "application/octet-stream"
                                let response = GCDWebServerDataResponse(data: data, contentType: contentType)
                                return response
                             })
        print("PharmaledgerMessageHandler - init - 3")
        let options: [String: Any] = [
            GCDWebServerOption_Port: findFreePort(),
            GCDWebServerOption_BindToLocalhost: true
        ]
        print("PharmaledgerMessageHandler - init - 4")
        do {
            try self.webserver.start(options: options)
        } catch {
            print(error)
        }
        print("PharmaledgerMessageHandler - init - 5")
    }
    
    deinit {
        print("PharmaledgerMessageHandler - deinit")
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
        print("PharmaledgerMessageHandler - getWebview")
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
        print("PharmaledgerMessageHandler - handleMessage")
        guard let webview = self.webview else {
            print("WebView was nil")
            return
        }
        print("PharmaledgerMessageHandler - message=\'\(message)\'")
        
        // string used as returned argument that can be passed back to js with the callback
        var jsonString: String = ""
        switch message {
        case .StartCamera:
            if let pWidth = args?["previewWidth"] as? Int {
                self.previewWidth = pWidth
            }
            handleCameraStart(onCameraInitializedJsCallback: args?["onInitializedJsCallback"] as? String,
                              sessionPreset: args?["sessionPreset"] as! String,
                              flash_mode: args?["flashMode"] as? String)
            jsonString = ""
        case .StopCamera:
            handleCameraStop()
            jsonString = ""
        case .TakePicture:
            handleTakePicture(onCaptureJsCallback: args?["onCaptureJsCallback"] as? String)
        case .SetFlashMode:
            handleSetFlashMode(mode: args?["mode"] as? String)
        }
        if let callback = jsCallback {
            if !callback.isEmpty {
                DispatchQueue.main.async {
                    let js = "document.getElementsByTagName('iframe')[0].contentWindow.\(jsCallback)(\"\(jsonString)\")"
                    print("PharmaledgerMessageHandler-handleMessage-js:\(js)")
                    
                     
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
    private func handleCameraStart(onCameraInitializedJsCallback: String?, sessionPreset: String, flash_mode: String?) {
        print("PharmaledgerMessageHandler - handleCameraStart")
        self.onCameraInitializedJsCallback = onCameraInitializedJsCallback
        self.cameraConfiguration = .init(flash_mode: flash_mode, color_space: nil, session_preset: sessionPreset, auto_orienation_enabled: false)
        self.cameraSession = .init(cameraEventListener: self, cameraConfiguration: self.cameraConfiguration!)
        return
    }
    
    private func handleCameraStop() {
        print("PharmaledgerMessageHandler - handleCameraStop")
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
    }
    
    private func handleTakePicture(onCaptureJsCallback: String?) {
        print("PharmaledgerMessageHandler - handleTakePicture")
        self.onCaptureJsCallback = onCaptureJsCallback
        self.cameraSession?.takePicture()
    }
    
    private func handleSetFlashMode(mode: String?) {
        print("PharmaledgerMessageHandler - handleSetFlashMode")
        guard let mode = mode, let cameraConfiguration = cameraConfiguration else {
            return
        }
        cameraConfiguration.setFlashConfiguration(flash_mode: mode)
    }
    
    private func callJsAfterCameraStart() {
        print("PharmaledgerMessageHandler - callJsAfterCameraStart")
        ///
        let port:UInt = self.webserver.port
        ///
        if let jsCallback = self.onCameraInitializedJsCallback {
            guard let webview = self.webview else {
                print("WebView was nil")
                return
            }
            let js = "document.getElementsByTagName('iframe')[0].contentWindow.\(jsCallback)(\"\(port)\")"
            print("PharmaledgerMessageHandler-callJsAfterCameraStart-js:\(js)")
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
}

