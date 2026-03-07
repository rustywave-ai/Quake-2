/*
 * GameControllerManager.swift
 * MFi and PS5 DualSense controller support via Game Controller framework
 */

import GameController
import CoreHaptics

class GameControllerManager {

    var onControllerConnected: (() -> Void)?
    var onControllerDisconnected: (() -> Void)?

    private var controller: GCController?
    private var hapticEngine: CHHapticEngine?

    /* Quake key codes */
    private let K_SPACE: Int32 = 32       /* Jump */
    private let K_ENTER: Int32 = 13       /* Use / interact */
    private let K_CTRL: Int32 = 157       /* Crouch */
    private let K_MOUSE1: Int32 = 179     /* Fire */
    private let K_MOUSE2: Int32 = 180     /* Alt fire / zoom */
    private let K_MWHEELUP: Int32 = 185   /* Next weapon */
    private let K_MWHEELDOWN: Int32 = 186 /* Prev weapon */
    private let K_ESCAPE: Int32 = 27      /* Menu / pause */
    private let K_GRAVE: Int32 = 96       /* Console toggle (backtick) */
    private let K_TAB: Int32 = 9          /* Inventory */
    private let K_UPARROW: Int32 = 128
    private let K_DOWNARROW: Int32 = 129
    private let K_LEFTARROW: Int32 = 130
    private let K_RIGHTARROW: Int32 = 131

    /* Input state */
    private var leftStickX: Float = 0
    private var leftStickY: Float = 0
    private var rightStickX: Float = 0
    private var rightStickY: Float = 0
    private let stickDeadZone: Float = 0.1
    private let lookSensitivity: Float = 3.0

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerConnected),
            name: .GCControllerDidConnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDisconnected),
            name: .GCControllerDidDisconnect, object: nil
        )

        /* Check for already-connected controllers */
        if let existing = GCController.controllers().first {
            configureController(existing)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hapticEngine?.stop()
    }

    // MARK: - Connection

    @objc private func controllerConnected(_ notification: Notification) {
        guard let gc = notification.object as? GCController else { return }
        configureController(gc)
        onControllerConnected?()
    }

    @objc private func controllerDisconnected(_ notification: Notification) {
        guard let gc = notification.object as? GCController, gc === controller else { return }
        controller = nil
        hapticEngine?.stop()
        hapticEngine = nil
        IOS_SetControllerConnected(0)
        onControllerDisconnected?()
    }

    private func configureController(_ gc: GCController) {
        controller = gc
        gc.playerIndex = .index1

        if let gamepad = gc.extendedGamepad {
            IOS_SetControllerConnected(1)
            configureExtendedGamepad(gamepad)
        }

        /* Set up haptics if DualSense */
        setupHaptics(gc)

        /* Configure adaptive triggers for DualSense */
        configureDualSenseTriggers(gc)
    }

    // MARK: - Gamepad Configuration

    private func configureExtendedGamepad(_ gamepad: GCExtendedGamepad) {
        /* Left thumbstick — movement */
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.leftStickX = x
            self?.leftStickY = y
        }

        /* Right thumbstick — look */
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.rightStickX = x
            self?.rightStickY = y
        }

        /* R2 — fire */
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_MOUSE1 ?? 0, down: pressed)
        }

        /* L2 — alt fire / zoom */
        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_MOUSE2 ?? 0, down: pressed)
        }

        /* Cross / A — jump */
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_SPACE ?? 0, down: pressed)
        }

        /* Circle / B — use / interact */
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_ENTER ?? 0, down: pressed)
        }

        /* Square / X — crouch */
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_CTRL ?? 0, down: pressed)
        }

        /* Triangle / Y — cycle weapons (next) */
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_MWHEELUP ?? 0, down: pressed)
        }

        /* L1 — previous weapon */
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_MWHEELDOWN ?? 0, down: pressed)
        }

        /* R1 — next weapon */
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_MWHEELUP ?? 0, down: pressed)
        }

        /* D-Pad */
        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_UPARROW ?? 0, down: pressed)
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_DOWNARROW ?? 0, down: pressed)
        }
        gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_LEFTARROW ?? 0, down: pressed)
        }
        gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_RIGHTARROW ?? 0, down: pressed)
        }

        /* Options / Menu — pause */
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_ESCAPE ?? 0, down: pressed)
        }

        /* Options (secondary) — inventory */
        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendKey(self?.K_TAB ?? 0, down: pressed)
        }

        /* DualSense touchpad press — console toggle */
        if let dualSense = gamepad as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.sendKey(self?.K_GRAVE ?? 0, down: pressed)
            }
        }
    }

    // MARK: - Input Polling

    func pollInput() {
        guard controller != nil else { return }

        /* Movement — left stick with dead zone */
        var mx = leftStickX
        var my = leftStickY
        if abs(mx) < stickDeadZone { mx = 0 }
        if abs(my) < stickDeadZone { my = 0 }
        IOS_SetJoystickInput(my, mx)

        /* Look — right stick with dead zone */
        var lx = rightStickX
        var ly = rightStickY
        if abs(lx) < stickDeadZone { lx = 0 }
        if abs(ly) < stickDeadZone { ly = 0 }
        if lx != 0 || ly != 0 {
            IOS_SetLookInput(lx * lookSensitivity, ly * lookSensitivity)
        }
    }

    // MARK: - Haptics (DualSense)

    private func setupHaptics(_ gc: GCController) {
        guard let haptics = gc.haptics else { return }
        guard haptics.supportedLocalities.contains(.default) else { return }

        do {
            hapticEngine = try haptics.createEngine(withLocality: .default)
            try hapticEngine?.start()
        } catch {
            NSLog("Failed to start haptic engine: %@", error.localizedDescription)
        }
    }

    /// Trigger a fire feedback haptic pulse
    func playFireHaptic() {
        guard let engine = hapticEngine else { return }
        do {
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7)
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [sharpness, intensity],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            /* Haptic failure is non-critical */
        }
    }

    /// Trigger a damage received haptic rumble
    func playDamageHaptic() {
        guard let engine = hapticEngine else { return }
        do {
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [sharpness, intensity],
                relativeTime: 0,
                duration: 0.2
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            /* Haptic failure is non-critical */
        }
    }

    // MARK: - DualSense Adaptive Triggers

    private func configureDualSenseTriggers(_ gc: GCController) {
        guard let dualSense = gc.extendedGamepad as? GCDualSenseGamepad else { return }

        /* R2 — weapon recoil resistance */
        dualSense.rightTrigger.setModeFeedbackWithStartPosition(0.1, resistiveStrength: 0.6)
    }

    // MARK: - Helpers

    private func sendKey(_ key: Int32, down: Bool) {
        IOS_KeyEvent(key, down ? 1 : 0)
    }
}
