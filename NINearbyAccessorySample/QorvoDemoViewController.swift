/*
 <samplecode>
  <abstract>
   A view controller that facilitates the Nearby Interaction Accessory user experience.
  </abstract>
</samplecode>
*/

import UIKit
import NearbyInteraction
import SceneKit
import CoreHaptics
import AVFoundation
import os.log

// An example messaging protocol for communications between the app and the
// accessory. In your app, modify or extend this enumeration to your app's
// user experience and conform the accessory accordingly.
enum MessageId: UInt8 {
    // Messages from the accessory.
    case accessoryConfigurationData = 0x1
    case accessoryUwbDidStart = 0x2
    case accessoryUwbDidStop = 0x3

    // Messages to the accessory.
    case initialize = 0xA
    case configureAndStart = 0xB
    case stop = 0xC
}

// Base struct for the feedback array implementing three different feedback levels
struct FeedbackLvl {
    var hummDuration: TimeInterval
    var timerIndexRef: Int
}

class AccessoryDemoViewController: UIViewController {

    @IBOutlet weak var connectionStateLabel: UILabel!
    @IBOutlet weak var uwbStateLabel: UILabel!
    @IBOutlet weak var infoLabel: UILabel!
    @IBOutlet weak var distanceLabel: UILabel!
    @IBOutlet weak var actionButton: UIButton!
    @IBOutlet weak var scanning: UIActivityIndicatorView!
    @IBOutlet weak var arrow3D: SCNView!
    @IBOutlet weak var swt3D: UISwitch!
    @IBOutlet weak var swtFeedback: UISwitch!

    var dataChannel = DataCommunicationChannel()
    var niSession = NISession()
    var configuration: NINearbyAccessoryConfiguration?
    var accessoryConnected = false
    var connectedAccessoryName: String?
    // A mapping from a discovery token to a name.
    var accessoryMap = [NIDiscoveryToken: String]()
    // Auxiliary variables for feedback
    var engine: CHHapticEngine?
    var feedbackDisabled: Bool = true
    var feedbackLevel: Int = 0
    var feedbackLevelOld: Int = 0
    var feedbackPar: [FeedbackLvl] = [FeedbackLvl(hummDuration: 1.0, timerIndexRef: 8),
                                      FeedbackLvl(hummDuration: 0.5, timerIndexRef: 4),
                                      FeedbackLvl(hummDuration: 0.1, timerIndexRef: 1)]
    // Auxiliary variables to handle the feedback Timer
    var timerIndex: Int = 0
    // Auxiliary variables to handle the 3D arrow
    var curAzimuth: Int = 0
    var curElevation: Int = 0
    var curSpin: Int = 0

    var testCounter: Int = 0

    let logger = os.Logger(subsystem: "com.example.apple-samplecode.NINearbyAccessorySample", category: "AccessoryDemoViewController")

    let btnRun = "Run Session"
    let btnStop = "Stop Session"
    let scene = SCNScene(named: "arrow_light_gray.usdz")

    override func viewDidLoad() {
        super.viewDidLoad()

        startArrow3DView()

        // Set a delegate for session updates from the framework.
        niSession.delegate = self

        // Prepare the data communication channel.
        dataChannel.accessoryConnectedHandler = accessoryConnected
        dataChannel.accessoryDisconnectedHandler = accessoryDisconnected
        dataChannel.accessoryDataHandler = accessorySharedData
        dataChannel.start()

        distanceLabel.backgroundColor = UIColor.clear

        // Action Button can be set to "Run" or "Stop" the Qorvo device
        actionButton.layer.borderWidth = 1
        actionButton.layer.borderColor = UIColor.darkGray.cgColor
        actionButton.setTitle(btnRun, for: .normal)

        // Initialises the Timer used for Haptic and Sound feedbacks
        _ = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(timerHandler), userInfo: nil, repeats: true)

        updateInfoLabel(with: "Scanning for accessories")
    }

    @IBAction func buttonAction(_ sender: Any) {
        var msg: Data

        if actionButton.titleLabel!.text == btnRun {
            updateInfoLabel(with: "Requesting configuration data from accessory")
            msg = Data([MessageId.initialize.rawValue])
        } else {
            updateInfoLabel(with: "Requesting accessory to stop")
            msg = Data([MessageId.stop.rawValue])
        }

        sendDataToAccessory(msg)
    }

    @objc func timerHandler() {
        // Feedback only enabled if the Qorvo device started ranging
        if (!swtFeedback.isOn || feedbackDisabled || !accessoryConnected ) { return }

        // As the timer is fast timerIndex and timerIndexRef provides a
        // pre-scaler to achieve different patterns
        if  timerIndex != feedbackPar[feedbackLevel].timerIndexRef {
            timerIndex += 1
            return
        }

        timerIndex = 0

        // Handles Sound, if enabled
        let systemSoundID: SystemSoundID = 1052
        AudioServicesPlaySystemSound(systemSoundID)

        // Handles Haptic, if enabled
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        var events = [CHHapticEvent]()

        let humm = CHHapticEvent(eventType: .hapticContinuous,
                                 parameters: [],
                                 relativeTime: 0,
                                 duration: feedbackPar[feedbackLevel].hummDuration)
        events.append(humm)

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: 0)
        } catch {
            print("Failed to play pattern: \(error.localizedDescription).")
        }
    }

    func setFeedbackLvl(distance: Float) {
        // Select feedback Level according to the distance
        if distance > 4.0 {
            feedbackLevel = 0
        }
        else if distance > 2.0{
            feedbackLevel = 1
        }
        else {
            feedbackLevel = 2
        }

        // If level changes, apply immediately
        if feedbackLevel != feedbackLevelOld {
            timerIndex = 0
            feedbackLevelOld = feedbackLevel
        }
    }

    // MARK: - 3D Arrow methods
    func startArrow3DView() {
        // Adding light to scene
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.position = SCNVector3(x: 0, y: 0, z: 20)
        scene?.rootNode.addChildNode(lightNode)

        // Creating and adding ambien light to scene
        let ambientLightNode = SCNNode()
        ambientLightNode.light = SCNLight()
        ambientLightNode.light?.type = .ambient
        ambientLightNode.light?.color = UIColor.darkGray
        scene?.rootNode.addChildNode(ambientLightNode)

        // If you don't want to fix manually the lights
        arrow3D.autoenablesDefaultLighting = true
        // Allow user to manipulate camera
        arrow3D.allowsCameraControl = false
        // Set background color
        arrow3D.backgroundColor = UIColor.clear
        // Set scene settings
        arrow3D.scene = scene
        arrow3D.isHidden = true

        initArrowPosition()
    }

    func initArrowPosition() {
        let degree = 1.0 * Float.pi / 180.0

        arrow3D.scene?.rootNode.eulerAngles.x -= 90 * degree

        curAzimuth = 0
        curElevation = 0
        curSpin = 0
    }

    func setArrowAngle(newElevation: Int, newAzimuth: Int) {
        let oneDegree = 1.0 * Float.pi / 180.0
        var deltaX, deltaY, deltaZ: Int

        if(swt3D.isOn){

            deltaX = newElevation - curElevation
            deltaY = newAzimuth - curAzimuth
            deltaZ = 0 - curSpin

            curElevation = newElevation
            curAzimuth = newAzimuth
            curSpin = 0
        } else {

            deltaX = 90 - curElevation
            deltaY = 0 - curAzimuth
            deltaZ = newAzimuth - curSpin

            curElevation = 90
            curAzimuth = 0
            curSpin = newAzimuth
        }
        arrow3D.scene?.rootNode.eulerAngles.x += Float(deltaX) * oneDegree
        arrow3D.scene?.rootNode.eulerAngles.y -= Float(deltaY) * oneDegree
        arrow3D.scene?.rootNode.eulerAngles.z -= Float(deltaZ) * oneDegree

    }

    // MARK: - Data channel methods

    func accessorySharedData(data: Data, accessoryName: String) {
        // The accessory begins each message with an identifier byte.
        // Ensure the message length is within a valid range.
        if data.count < 1 {
            updateInfoLabel(with: "Accessory shared data length was less than 1.")
            return
        }

        // Assign the first byte which is the message identifier.
        guard let messageId = MessageId(rawValue: data.first!) else {
            fatalError("\(data.first!) is not a valid MessageId.")
        }

        // Handle the data portion of the message based on the message identifier.
        switch messageId {
        case .accessoryConfigurationData:
            // Access the message data by skipping the message identifier.
            assert(data.count > 1)
            let message = data.advanced(by: 1)
            setupAccessory(message, name: accessoryName)
        case .accessoryUwbDidStart:
            handleAccessoryUwbDidStart()
        case .accessoryUwbDidStop:
            handleAccessoryUwbDidStop()
        case .configureAndStart:
            fatalError("Accessory should not send 'configureAndStart'.")
        case .initialize:
            fatalError("Accessory should not send 'initialize'.")
        case .stop:
            fatalError("Accessory should not send 'stop'.")
        }
    }

    func accessoryConnected(name: String) {
        accessoryConnected = true

        connectedAccessoryName = name
        actionButton.isEnabled = true
        scanning.stopAnimating()
        connectionStateLabel.text = "Connected"
        updateInfoLabel(with: "Accessory connected")
    }

    func accessoryDisconnected() {
        accessoryConnected = false

        actionButton.setTitle(btnRun, for: .normal)
        actionButton.setTitleColor(UIColor.systemBlue, for: .normal)
        actionButton.setTitleColor(UIColor.lightGray, for: .disabled)
        actionButton.isEnabled = false

        scanning.startAnimating()
        distanceLabel.text = String(format: "")
        distanceLabel.sizeToFit()
        connectedAccessoryName = nil
        connectionStateLabel.text = "Not Connected"
        updateInfoLabel(with: "Accessory disconnected")
    }

    // MARK: - Accessory messages handling

    func setupAccessory(_ configData: Data, name: String) {
        updateInfoLabel(with: "Received configuration data. Running session.")
        do {
            configuration = try NINearbyAccessoryConfiguration(data: configData)
        } catch {
            // Stop and display the issue because the incoming data is invalid.
            // In your app, debug the accessory data to ensure an expected
            // format.
            updateInfoLabel(with: "Failed to create NINearbyAccessoryConfiguration. Error: \(error)")
            return
        }

        // Cache the token to correlate updates with this accessory.
        cacheToken(configuration!.accessoryDiscoveryToken, accessoryName: name)
        niSession.run(configuration!)
    }

    func handleAccessoryUwbDidStart() {
        updateInfoLabel(with: "Accessory session started.")
        // Change Action button to "Stop"
        actionButton.setTitle(btnStop, for: .normal)
        actionButton.setTitleColor(UIColor.red, for: .normal)
        // Handles 3D Arrow and Feedback when Qorvo device started ranging
        arrow3D.isHidden = false
        feedbackDisabled = false
        distanceLabel.isHidden = false

        self.uwbStateLabel.text = "ON"
    }

    func handleAccessoryUwbDidStop() {
        updateInfoLabel(with: "Accessory session stopped.")
        // Change Action button to "Run"
        actionButton.setTitle(btnRun, for: .normal)
        actionButton.setTitleColor(UIColor.systemBlue, for: .normal)
        // Handles 3D Arrow and Feedback when Qorvo device is not ranging
        arrow3D.isHidden = true
        feedbackDisabled = true
        distanceLabel.isHidden = true

        self.uwbStateLabel.text = "OFF"
    }
}

// MARK: - `NISessionDelegate`.

extension AccessoryDemoViewController: NISessionDelegate {

    func session(_ session: NISession, didGenerateShareableConfigurationData shareableConfigurationData: Data, for object: NINearbyObject) {
        guard object.discoveryToken == configuration?.accessoryDiscoveryToken else { return }

        // Prepare to send a message to the accessory.
        var msg = Data([MessageId.configureAndStart.rawValue])
        msg.append(shareableConfigurationData)

        let str = msg.map { String(format: "0x%02x, ", $0) }.joined()
        logger.info("Sending shareable configuration bytes: \(str)")

        //let accessoryName = accessoryMap[object.discoveryToken] ?? "Unknown"

        // Send the message to the accessory.
        sendDataToAccessory(msg)
        updateInfoLabel(with: "Sent shareable configuration data.")
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let accessory = nearbyObjects.first else { return }
        guard var distance = accessory.distance else { return }
        guard var direction = accessory.direction else { return }

        if !accessoryConnected { return }

        // Apply a moving average filter to distance and direction
        includeDistance(distance)
        distance = getAvgDistance()

        includeDirection(direction)
        direction = getAvgDirection()

        // Calculates azimuth and elevation from the average result
        let azimuth = Int(90 * azimuth(direction))
        let elevation = Int(90 * elevation(direction))

        // Update Label
        self.distanceLabel.text = String(format: "\n\n\n\n\n\n\n%0.1f meters away\nAzimuth: %d°\nElevation: %d°", distance, azimuth, elevation)
        self.distanceLabel.sizeToFit()

        // Update Graphics
        setArrowAngle(newElevation: elevation, newAzimuth: azimuth)

        // Update Feedback Level
        setFeedbackLvl(distance: distance)
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        // Retry the session only if the peer timed out.
        guard reason == .timeout else { return }
        updateInfoLabel(with: "Session timed out.")

        // The session runs with one accessory.
        guard let accessory = nearbyObjects.first else { return }

        // Clear the app's accessory state.
        accessoryMap.removeValue(forKey: accessory.discoveryToken)

        // Consult helper function to decide whether or not to retry.
        if shouldRetry(accessory) {
//            sendDataToAccessory(Data([MessageId.stop.rawValue]))
//            sendDataToAccessory(Data([MessageId.initialize.rawValue]))
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        updateInfoLabel(with: "Session was suspended.")
        let msg = Data([MessageId.stop.rawValue])
        sendDataToAccessory(msg)
    }

    func sessionSuspensionEnded(_ session: NISession) {
        updateInfoLabel(with: "Session suspension ended.")
        // When suspension ends, restart the configuration procedure with the accessory.
        let msg = Data([MessageId.initialize.rawValue])
        sendDataToAccessory(msg)
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        switch error {
        case NIError.invalidConfiguration:
            // Debug the accessory data to ensure an expected format.
            updateInfoLabel(with: "The accessory configuration data is invalid. Please debug it and try again.")
        case NIError.userDidNotAllow:
            handleUserDidNotAllow()
        default:
            handleSessionInvalidation()
        }
    }
}

// MARK: - Helpers.

extension AccessoryDemoViewController {

    func updateInfoLabel(with text: String) {
        let infoUpdate = (connectedAccessoryName ?? "not") + " connected.\n" + text

        self.infoLabel.text = infoUpdate
        self.infoLabel.sizeToFit()
        logger.info("\(text)")
    }

    func sendDataToAccessory(_ data: Data) {
        do {
            try dataChannel.sendData(data)
        } catch {
            updateInfoLabel(with: "Failed to send data to accessory: \(error)")
        }
    }

    func handleSessionInvalidation() {
        updateInfoLabel(with: "Session invalidated. Restarting.")
        // Ask the accessory to stop.
        sendDataToAccessory(Data([MessageId.stop.rawValue]))

        // Replace the invalidated session with a new one.
        self.niSession = NISession()
        self.niSession.delegate = self

        // Ask the accessory to stop.
        sendDataToAccessory(Data([MessageId.initialize.rawValue]))
    }

    func shouldRetry(_ accessory: NINearbyObject) -> Bool {
        if accessoryConnected {
            return true
        }
        return false
    }

    func cacheToken(_ token: NIDiscoveryToken, accessoryName: String) {
        accessoryMap[token] = accessoryName
    }

    func handleUserDidNotAllow() {
        // Beginning in iOS 15, persistent access state in Settings.
        updateInfoLabel(with: "Nearby Interactions access required. You can change access for NIAccessory in Settings.")

        // Create an alert to request the user go to Settings.
        let accessAlert = UIAlertController(title: "Access Required",
                                            message: """
                                            NIAccessory requires access to Nearby Interactions for this sample app.
                                            Use this string to explain to users which functionality will be enabled if they change
                                            Nearby Interactions access in Settings.
                                            """,
                                            preferredStyle: .alert)
        accessAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        accessAlert.addAction(UIAlertAction(title: "Go to Settings", style: .default, handler: {_ in
            // Navigate the user to the app's settings.
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
            }
        }))

        // Preset the access alert.
        present(accessAlert, animated: true, completion: nil)
    }
}

// MARK: - Utils.
var distArray: Array<Float> = Array(repeating: 0, count: 10)
let zeroVector = simd_make_float3(0, 0, 0)
var diretArray: Array<simd_float3> = Array(repeating: zeroVector, count: 10)
var avgDistIndex = 0
var avgDiretIndex = 0

// Provides the azimuth from an argument 3D directional.
func azimuth(_ direction: simd_float3) -> Float {
    return asin(direction.x)
}

// Provides the elevation from the argument 3D directional.
func elevation(_ direction: simd_float3) -> Float {
    return atan2(direction.z, direction.y) + .pi / 2
}

func includeDistance(_ value: Float) {

    distArray[avgDistIndex] = value

    if avgDistIndex < (distArray.count - 1) {
        avgDistIndex += 1
    }
    else {
        avgDistIndex = 0
    }
}

func getAvgDistance() -> Float {
    var sumValue: Float

    sumValue = 0

    for value in distArray {
        sumValue += value
    }

    return Float(sumValue)/Float(distArray.count)
}

func includeDirection(_ value: simd_float3) {

    diretArray[avgDiretIndex] = value

    if avgDiretIndex < (diretArray.count - 1) {
        avgDiretIndex += 1
    }
    else {
        avgDiretIndex = 0
    }
}

func getAvgDirection() -> simd_float3 {
    var sumValue: simd_float3

    sumValue = zeroVector

    for value in diretArray {
        sumValue += value
    }

    return simd_float3(sumValue)/Float(diretArray.count)
}
