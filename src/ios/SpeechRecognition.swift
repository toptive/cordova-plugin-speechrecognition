//
//  SpeechRecognition.swift
//  Simplifier
//
//  Created by Florian Pechwitz on 21.11.19.
//

import Speech
import AVFoundation

@objc (SpeechRecognition) class SpeechRecognition : CDVPlugin {
    private static let DEFAULT_MATCHES: Int = 5

    private static let MESSAGE_MISSING_PERMISSION: String = "Missing permission"
    private static let MESSAGE_ACCESS_DENIED: String = "User denied access to speech recognition"
    private static let MESSAGE_RESTRICTED: String = "Speech recognition restricted on this device"
    private static let MESSAGE_NOT_DETERMINED: String = "Speech recognition not determined on this device"
    private static let MESSAGE_ACCESS_DENIED_MICROPHONE: String = "User denied access to microphone"
    private static let MESSAGE_ONGOING: String = "Ongoing speech recognition"
    private static let MESSAGE_NOT_AVAILABLE: String = "Speech recognition not available"

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var resultArray = [String]()
    private var resultTimer: Timer?

    @objc (isRecognitionAvailable:)
    func isRecognitionAvailable(command: CDVInvokedUrlCommand){
        var pluginResult = CDVPluginResult()

        if #available(iOS 10.0, *) {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: true)
        } else {
            pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: false)
        }
        commandDelegate.send(pluginResult, callbackId:command.callbackId)
    }

    @objc (startListening:)
    func startListening(command: CDVInvokedUrlCommand){
        if self.audioEngine?.isRunning ?? false {
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_ONGOING)
            self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
            return
        }

        NSLog("startListening()");

        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            NSLog("startListening() microphone access not authorized")
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_MISSING_PERMISSION)
            self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
            return
        }

        let language: String? = command.argument(at: 0, withDefault: nil) as? String
        let matches: Int = command.argument(at: 1, withDefault: SpeechRecognition.DEFAULT_MATCHES) as? Int
            ?? SpeechRecognition.DEFAULT_MATCHES
        let showPartial: Bool = command.argument(at: 3, withDefault: false) as? Bool ?? false

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord)
            try audioSession.setMode(AVAudioSession.Mode.measurement)
            try audioSession.setActive(true)
        } catch let error {
            NSLog(String(describing: error))
            self.stopListening()
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: String(describing: error))
            self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
            return
        }

        if  let language = language {
            let locale = Locale(identifier: language)
            self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        } else {
            self.speechRecognizer = SFSpeechRecognizer()
        }

        if !(self.speechRecognizer?.isAvailable ?? false) {
            NSLog("SpeechRecognizer is not available")
            self.stopListening()
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_NOT_AVAILABLE)
            self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
            return
        }
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.audioEngine = AVAudioEngine()

        let inputNode = self.audioEngine!.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }

        self.recognitionRequest?.shouldReportPartialResults = true

        self.recognitionTask = self.speechRecognizer?.recognitionTask(with: self.recognitionRequest!, resultHandler: { (result, error) in
            guard let result = result else {
                NSLog("startListening() recognitionTask error: \(String(describing: error!))")
                self.stopListening()

                self.recognitionTask?.cancel()
                self.recognitionTask = nil
                self.speechRecognizer = nil

                let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: String(describing: error!))
                if showPartial {
                    pluginResult?.setKeepCallbackAs(true)
                }
                self.commandDelegate.send(pluginResult, callbackId:command.callbackId)

                return
            }

            self.resultArray = [String]()

            var counter: Int = 0;
            for transcription in result.transcriptions {
                if matches > 0 && counter < matches {
                    self.resultArray.append(transcription.formattedString)
                }
                counter+=1
            }

            NSLog("startListening() recognitionTask result array: \(self.resultArray.description)")
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: self.resultArray)
            if showPartial {
                pluginResult?.setKeepCallbackAs(true)
                self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
            } else {
                self.resultTimer?.invalidate()
                self.resultTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false, block: { (timer) in
                    NSLog("startListening() timeout")
                    self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
                    self.stopListening()
                    self.resultTimer = nil
                })
                // Improving performance by adding a tolerance
                self.resultTimer?.tolerance = 0.1
            }

            if result.isFinal {
                NSLog("startListening() recognitionTask isFinal")
                self.stopListening()
                self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
            }
        })

        self.audioEngine?.prepare()
        do {
            try self.audioEngine?.start()
        } catch (let error) {
            NSLog(String(describing: error))
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: String(describing: error))
            self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
            return
        }
    }

    @objc (stopListening:)
    func stopListening(command: CDVInvokedUrlCommand){
        self.commandDelegate.run {
            self.stopListening()

            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK)
            self.commandDelegate.send(pluginResult, callbackId: command.callbackId)
        }
    }

    private func stopListening() {
        NSLog("stopListening()")
        self.resultTimer?.invalidate()
        self.resultTimer = nil
        self.audioEngine?.inputNode.removeTap(onBus: 0)
        self.audioEngine?.stop()
        self.recognitionRequest?.endAudio()
        self.audioEngine = nil
        self.recognitionRequest = nil
        self.speechRecognizer = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(AVAudioSession.Category.playback)
            try audioSession.setMode(AVAudioSession.Mode.default)
            try audioSession.setActive(true)
        } catch let error {
            NSLog(String(describing: error))
        }

        self.recognitionTask?.cancel()
        self.recognitionTask = nil
    }

    @objc (getSupportedLanguages:)
    func getSupportedLanguages(command: CDVInvokedUrlCommand){
        let supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales()

        var localesArray = [String]()

        for locale in supportedLocales {
            localesArray.append(locale.identifier)
        }

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: localesArray)
        commandDelegate.send(pluginResult, callbackId:command.callbackId)
    }

    @objc (hasPermission:)
    func hasPermission(command: CDVInvokedUrlCommand){
        let status = SFSpeechRecognizer.authorizationStatus()

        if status != .authorized {
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: false)
            commandDelegate.send(pluginResult, callbackId:command.callbackId)
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
            let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAs: granted)
            self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
        }
    }

    @objc (requestPermission:)
    func requestPermission(command: CDVInvokedUrlCommand){
        SFSpeechRecognizer.requestAuthorization { (status) in
            var pluginResult = CDVPluginResult()

            switch status {
            case .denied:
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_ACCESS_DENIED)
                break
            case .restricted:
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_RESTRICTED)
                break
            case .notDetermined:
                pluginResult = CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_NOT_DETERMINED)
                break
            case .authorized:
                break
            }

            if status != .authorized {
                DispatchQueue.main.async {
                    self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
                }
                return
            }

            AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
                pluginResult = granted ?
                    CDVPluginResult(status: CDVCommandStatus_OK, messageAs: true)
                    : CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: SpeechRecognition.MESSAGE_ACCESS_DENIED_MICROPHONE)
                DispatchQueue.main.async {
                    self.commandDelegate.send(pluginResult, callbackId:command.callbackId)
                }
            }
        }
    }
}
