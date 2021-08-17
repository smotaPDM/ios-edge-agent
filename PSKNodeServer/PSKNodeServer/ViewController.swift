//
//  ViewController.swift
//  PSSmartWalletNativeLayerDemo
//
//  Created by Costin Andronache on 10/22/20.
//

import UIKit
import PSSmartWalletNativeLayer
import WebKit

class ViewController: UIViewController,WKUIDelegate {
    
    private var messageHandler: PharmaledgerMessageHandler?
    
    private let ac = ApplicationCore()
    
    private var webView :WKWebView?
    
    @IBOutlet private var webHostView: PSKWebViewHostView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let dirPath = Bundle.main.path(forResource: "nodejsProject", ofType: nil)
        self.messageHandler = PharmaledgerMessageHandler(staticPath: dirPath)
        
        view.backgroundColor = Configuration.defaultInstance.webviewBackgroundColor
        
        webView = messageHandler?.getWebview(frame: self.view.frame)
        webView!.uiDelegate = self
        webHostView?.constrain(webView: webView!)
        
        ac.setupStackIn(hostController: self) { [weak self] (result) in
            switch result {
            case .success(let url):
                self?.webView?.load(.init(url: url))
            case .failure(let error):
                let message = "\(error.description)\n\("error_final_words".localized)"
                UIAlertController.okMessage(in: self, message: message, completion: nil)
            }
            
        } reloadCallback: { [weak self] result in
            switch result {
            case .success:
                return
            case .failure(let error):
                UIAlertController.okMessage(in: self, message: "\(error.description)\n\("error_final_words".localized)", completion: nil)
            }
        }

    }
    
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: {action in completionHandler() }))
        self.present(alert, animated: true, completion: nil)
    }
    
    
    public func removeWebview() {
        //TODO: check if this function is needed. Don't put this on viewDid/WillDisappear
        if let webview = webView {
            if let messageHandler = self.messageHandler {
                if let cameraSession = messageHandler.cameraSession {
                    if let captureSession = cameraSession.captureSession {
                        if captureSession.isRunning {
                            cameraSession.stopCamera()
                        }
                    }
                    messageHandler.cameraSession = nil
                }
            }
            if #available(iOS 14.0, *) {
                webview.configuration.userContentController.removeAllScriptMessageHandlers()
            }
            self.messageHandler = nil
            webview.removeFromSuperview()
            self.webView = nil
        }
    }

    func loadURL(string: String) {
        if let url = URL(string: string) {
            webView?.load(URLRequest(url: url))
        }
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }
}

extension ApplicationCore.SetupError {
    var description: String {
        switch self {
        case .nodePortSearchFail:
            return "port_search_fail_node".localized
        case .apiContainerPortSearchFail:
            return "port_search_fail_ac".localized
        case .apiContainerSetupFailed(let error):
            return "\("ac_setup_failed".localized) \(error.localizedDescription)"
        case .nspSetupError(let error):
            return "\("nsp_setup_failed".localized) \(error.localizedDescription)"
        case .webAppCopyError(let error):
            return "\("web_app_copy_failed".localized) \(error.localizedDescription)"
        case .unknownError(let error):
            return "\("unknown_error".localized) \(error.localizedDescription)"
        }
    }
}

extension ApplicationCore.RestartError {
    var description: String {
        switch self {
        case .foregroundRestartError(let error):
            return "\("unknown_error".localized) \(error.localizedDescription)"
        }
    }
}
