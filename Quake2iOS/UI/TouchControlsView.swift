/*
 * TouchControlsView.swift
 * Transparent overlay for touch input — virtual joystick + look + action buttons
 */

import UIKit

class TouchControlsView: UIView {

    /* Quake key codes (from client/keys.h) */
    private let K_ENTER: Int32 = 13       /* Select */
    private let K_ESCAPE: Int32 = 27      /* Menu */
    private let K_SPACE: Int32 = 32       /* Jump */
    private let K_UPARROW: Int32 = 128
    private let K_DOWNARROW: Int32 = 129
    private let K_LEFTARROW: Int32 = 130
    private let K_RIGHTARROW: Int32 = 131
    private let K_MOUSE1: Int32 = 200     /* Fire — K_MOUSE1 */

    /* Use AUX keys for touch buttons — bound to commands in IN_Init */
    private let K_AUX1: Int32 = 207       /* Crouch → +movedown */
    private let K_AUX2: Int32 = 208       /* Weapon next → weapnext */
    private let K_AUX3: Int32 = 209       /* Weapon prev → weapprev */
    private let K_AUX4: Int32 = 210       /* D-pad forward → +forward */
    private let K_AUX5: Int32 = 211       /* D-pad back → +back */
    private let K_AUX6: Int32 = 212       /* D-pad strafe left → +moveleft */
    private let K_AUX7: Int32 = 213       /* D-pad strafe right → +moveright */

    /* Sub-views */
    private let joystick = VirtualJoystick()
    private let lookJoystick = VirtualJoystick()
    private var actionButtons: [ActionButton] = []
    private var menuNavButtons: [ActionButton] = []
    private var gearButton: ActionButton?

    /* Game state — action buttons hidden until a real game starts */
    private(set) var gameControlsVisible = false {
        didSet {
            for btn in actionButtons { btn.isHidden = !gameControlsVisible }
            gearButton?.isHidden = !gameControlsVisible
            /* Clear stale input when transitioning into gameplay */
            if gameControlsVisible && !oldValue {
                IOS_ClearInputState()
                /* Reset Swift-side joystick key state to match */
                joyFwdDown = false
                joyBackDown = false
                joyLeftDown = false
                joyRightDown = false
            }
        }
    }

    /* Menu navigation state — D-pad + Enter/Back shown when menu is active */
    private(set) var menuNavVisible = false {
        didSet {
            for btn in menuNavButtons { btn.isHidden = !menuNavVisible }
            gearButton?.isHidden = !gameControlsVisible
        }
    }

    /* Touch tracking */
    private var lookTouch: UITouch?
    private var joystickTouch: UITouch?

    /* Look joystick speed — degrees per frame at full deflection */
    private let lookSpeed: Float = 20.0

    /* Button touch tracking — maps each touch to its button so UP events
       are always sent even if the finger slides off the button */
    private var buttonTouches: [ObjectIdentifier: ActionButton] = [:]

    /* Joystick zone: left 35% of screen */
    private var joystickZoneWidth: CGFloat { bounds.width * 0.35 }

    /* D-pad threshold for joystick → key events */
    private let dpadThreshold: Float = 0.3

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear

        addSubview(joystick)
        addSubview(lookJoystick)
        setupButtons()
        setupGearButton()
        setupMenuNavButtons()

        /* Start with all buttons hidden */
        for btn in actionButtons { btn.isHidden = true }
        for btn in menuNavButtons { btn.isHidden = true }
        gearButton?.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        joystick.frame = bounds
        lookJoystick.frame = bounds
        layoutButtons()
        layoutMenuNavButtons()
    }

    /// Called each frame to apply continuous look input from the look joystick.
    /// Unlike movement (threshold-based key events), look input is analog —
    /// the further the stick is deflected, the faster the view rotates.
    func applyLookInput() {
        guard lookJoystick.isActive else { return }
        let x = lookJoystick.xAxis
        let y = lookJoystick.yAxis
        if x != 0 || y != 0 {
            IOS_SetLookInput(x * lookSpeed, -y * lookSpeed)
        }
    }

    /// Called each frame to sync game controls visibility with engine state.
    /// Action buttons only appear when the player is in an actual game
    /// (not during attract/demo loop or disconnected state).
    func updateGameState() {
        let inGame = IOS_IsInGame() != 0 && IOS_IsInCinematic() == 0
        let shouldShow = inGame && IOS_IsMenuActive() == 0
        if shouldShow != gameControlsVisible {
            gameControlsVisible = shouldShow
        }
        let menuActive = IOS_IsMenuActive() != 0
        if menuActive != menuNavVisible {
            menuNavVisible = menuActive
        }
    }

    // MARK: - Buttons

    private func setupButtons() {
        let buttonDefs: [(String, Int32)] = [
            ("Fire", K_MOUSE1),       /* 0: right-side fire */
            ("Jump", K_SPACE),        /* 1: jump */
            ("Crouch", K_AUX1),       /* 2: crouch */
            ("\u{25B2}", K_AUX2),     /* 3: weapon next */
            ("\u{25BC}", K_AUX3),     /* 4: weapon prev */
            ("Fire", K_MOUSE1),       /* 5: left-side fire */
        ]
        for (title, key) in buttonDefs {
            let btn = ActionButton(title: title, keyCode: key)
            addSubview(btn)
            actionButtons.append(btn)
        }
    }

    private func setupGearButton() {
        /* Gear icon — opens/closes menu (pauses SP game) */
        let gear = ActionButton(title: "\u{2699}\u{FE0F}", keyCode: K_ESCAPE, fontSize: 22)
        gear.backgroundColor = UIColor(white: 0.15, alpha: 0.5)
        gear.layer.borderWidth = 1.0
        addSubview(gear)
        gearButton = gear
    }

    private func setupMenuNavButtons() {
        let navDefs: [(String, Int32)] = [
            ("\u{25B2}", K_UPARROW),      /* 0: up */
            ("\u{25BC}", K_DOWNARROW),     /* 1: down */
            ("\u{25C0}", K_LEFTARROW),     /* 2: left */
            ("\u{25B6}", K_RIGHTARROW),    /* 3: right */
            ("OK", K_ENTER),               /* 4: enter/select */
            ("\u{2190}", K_ESCAPE),        /* 5: back */
        ]
        for (title, key) in navDefs {
            let btn = ActionButton(title: title, keyCode: key, fontSize: 18)
            addSubview(btn)
            menuNavButtons.append(btn)
        }
    }

    private func layoutMenuNavButtons() {
        let safeArea = safeAreaInsets
        let btnSize: CGFloat = 44
        let gap: CGFloat = 22  /* >= btnSize/2 to prevent overlap in cross layout */

        /* D-pad center — left side of screen */
        let dpadCX = safeArea.left + 20 + btnSize + gap / 2
        let dpadCY = bounds.height / 2

        /* Up */
        if menuNavButtons.count > 0 {
            menuNavButtons[0].frame = CGRect(
                x: dpadCX - btnSize / 2,
                y: dpadCY - btnSize - gap,
                width: btnSize, height: btnSize
            )
            menuNavButtons[0].layer.cornerRadius = btnSize / 4
        }
        /* Down */
        if menuNavButtons.count > 1 {
            menuNavButtons[1].frame = CGRect(
                x: dpadCX - btnSize / 2,
                y: dpadCY + gap,
                width: btnSize, height: btnSize
            )
            menuNavButtons[1].layer.cornerRadius = btnSize / 4
        }
        /* Left */
        if menuNavButtons.count > 2 {
            menuNavButtons[2].frame = CGRect(
                x: dpadCX - btnSize - gap,
                y: dpadCY - btnSize / 2,
                width: btnSize, height: btnSize
            )
            menuNavButtons[2].layer.cornerRadius = btnSize / 4
        }
        /* Right */
        if menuNavButtons.count > 3 {
            menuNavButtons[3].frame = CGRect(
                x: dpadCX + gap,
                y: dpadCY - btnSize / 2,
                width: btnSize, height: btnSize
            )
            menuNavButtons[3].layer.cornerRadius = btnSize / 4
        }

        /* Enter/Back — right side of screen */
        let rightX = bounds.width - safeArea.right - 20 - 60
        let centerY = bounds.height / 2

        /* Enter (OK) */
        if menuNavButtons.count > 4 {
            menuNavButtons[4].frame = CGRect(
                x: rightX,
                y: centerY - btnSize - gap / 2,
                width: 60, height: btnSize
            )
            menuNavButtons[4].layer.cornerRadius = btnSize / 4
        }
        /* Back */
        if menuNavButtons.count > 5 {
            menuNavButtons[5].frame = CGRect(
                x: rightX,
                y: centerY + gap / 2,
                width: 60, height: btnSize
            )
            menuNavButtons[5].layer.cornerRadius = btnSize / 4
        }
    }

    private func layoutButtons() {
        let safeArea = safeAreaInsets
        let btnSize: CGFloat = 56
        let spacing: CGFloat = 12
        let rightMargin = bounds.width - safeArea.right - 20
        let bottomMargin = bounds.height - safeArea.bottom - 20

        /* Fire — large button, bottom right */
        if actionButtons.count > 0 {
            let fire = actionButtons[0]
            fire.frame = CGRect(
                x: rightMargin - 70,
                y: bottomMargin - 70,
                width: 70, height: 70
            )
            fire.layer.cornerRadius = 35
        }

        /* Jump — above fire */
        if actionButtons.count > 1 {
            let jump = actionButtons[1]
            jump.frame = CGRect(
                x: rightMargin - btnSize - 10,
                y: bottomMargin - 70 - spacing - btnSize,
                width: btnSize, height: btnSize
            )
            jump.layer.cornerRadius = btnSize / 2
        }

        /* Crouch — left of fire */
        if actionButtons.count > 2 {
            let crouch = actionButtons[2]
            crouch.frame = CGRect(
                x: rightMargin - 70 - spacing - btnSize,
                y: bottomMargin - btnSize,
                width: btnSize, height: btnSize
            )
            crouch.layer.cornerRadius = btnSize / 2
        }

        /* Weapon next — top right area */
        if actionButtons.count > 3 {
            let wepUp = actionButtons[3]
            wepUp.frame = CGRect(
                x: rightMargin - btnSize,
                y: safeArea.top + 60,
                width: 44, height: 44
            )
            wepUp.layer.cornerRadius = 22
        }

        /* Weapon prev — below weapon next */
        if actionButtons.count > 4 {
            let wepDown = actionButtons[4]
            wepDown.frame = CGRect(
                x: rightMargin - btnSize,
                y: safeArea.top + 60 + 44 + spacing,
                width: 44, height: 44
            )
            wepDown.layer.cornerRadius = 22
        }

        /* Left-side fire — upper left for index finger (CoDM/PUBG style) */
        if actionButtons.count > 5 {
            let leftFire = actionButtons[5]
            leftFire.frame = CGRect(
                x: safeArea.left + 20,
                y: safeArea.top + 60,
                width: 64, height: 64
            )
            leftFire.layer.cornerRadius = 32
        }

        /* Gear button — top-right, industry-standard position */
        if let gear = gearButton {
            gear.frame = CGRect(
                x: rightMargin - 40,
                y: safeArea.top + 12,
                width: 40, height: 40
            )
            gear.layer.cornerRadius = 20
        }
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        /* Block all input during LOADING screens (level transitions).
           Without this, stray touches hit the K_ESCAPE fallback and
           open the menu mid-load, causing state corruption. */
        if IOS_IsLoading() != 0 { return }

        /* If the engine is paused by an external interruption (e.g. control
           center / notifications pulled down) and we're NOT in a menu,
           any touch resumes the game and is consumed.  Menus set paused=1
           normally, so we must not intercept touches in that case. */
        if IOS_GetPausedState() != 0 && IOS_IsMenuActive() == 0 {
            Quake2_Resume()
            return
        }

        for touch in touches {
            let point = touch.location(in: self)

            /* Gear button — check whenever it's visible (in-game or menu) */
            if let gear = gearButton, !gear.isHidden {
                if gear.frame.insetBy(dx: -10, dy: -10).contains(point) {
                    sendKeyTap(K_ESCAPE)
                    continue
                }
            }

            /* Menu navigation — check D-pad/Enter/Back buttons, then
               fall through to touch handling for quit/main menu */
            if IOS_IsMenuActive() != 0 {
                if handleButtonTouchBegan(touch) {
                    continue
                }
                handleMenuTouch(at: point)
                continue
            }

            /* During a cutscene, any tap skips it.
               Q2 skips cinematics when cmd->buttons is set (cl_input.c:494),
               so we send a fire (K_MOUSE1) press, not K_ESCAPE (which opens the menu). */
            if IOS_IsInCinematic() != 0 {
                sendKeyTap(K_MOUSE1)
                continue
            }

            /* Before a game starts, any tap opens the menu */
            if !gameControlsVisible {
                sendKeyTap(K_ESCAPE)
                continue
            }

            /* ── In-game touch zones ── */

            /* Action buttons first — exact frame hit test (no expansion)
               so D-pad buttons on the left side can be tapped. */
            if handleButtonTouchBegan(touch) {
                continue
            }

            /* Joystick zone (left 35%) — only if no button was hit */
            if point.x < joystickZoneWidth && joystickTouch == nil {
                joystickTouch = touch
                joystick.touchBegan(at: point)
                updateMovementInput()
                continue
            }

            /* Right zone — look joystick */
            if lookTouch == nil {
                lookTouch = touch
                lookJoystick.touchBegan(at: point)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)

            guard gameControlsVisible else { continue }

            if touch === joystickTouch {
                joystick.touchMoved(to: point)
                updateMovementInput()
            } else if touch === lookTouch {
                lookJoystick.touchMoved(to: point)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            /* Release button via touch tracking dictionary */
            handleButtonTouchEnded(touch)

            if touch === lookTouch {
                lookTouch = nil
                lookJoystick.touchEnded()
            } else if touch === joystickTouch {
                joystickTouch = nil
                joystick.touchEnded()
                updateMovementInput()
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: - Menu Touch Navigation

    private func handleMenuTouch(at point: CGPoint) {
        /* Delegate to C-level hit testing which maps touch coordinates
         * directly to menu items using Q2's rendering positions.
         * Touch on an item → activates it.
         * Touch outside items → closes menu or goes back a level. */
        IOS_MenuTouchAt(Int32(point.x), Int32(point.y))
    }

    private func sendKeyTap(_ key: Int32) {
        IOS_KeyEvent(key, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            IOS_KeyEvent(key, 0)
        }
    }

    // MARK: - Joystick → Movement

    /* Joystick movement state — track which directions are active to
       send Key_Event only on transitions (down→up or up→down). */
    private var joyFwdDown = false
    private var joyBackDown = false
    private var joyLeftDown = false
    private var joyRightDown = false

    /// Converts joystick axis values into Key_Event calls using the same
    /// proven path as the D-pad buttons (IOS_KeyEvent → Key_Event → AUX
    /// binding → +forward/+back/+moveleft/+moveright).
    private func updateMovementInput() {
        let fwd   = joystick.yAxis >  dpadThreshold
        let back  = joystick.yAxis < -dpadThreshold
        let left  = joystick.xAxis < -dpadThreshold
        let right = joystick.xAxis >  dpadThreshold

        if fwd != joyFwdDown {
            joyFwdDown = fwd
            IOS_KeyEvent(K_AUX4, fwd ? 1 : 0)
        }
        if back != joyBackDown {
            joyBackDown = back
            IOS_KeyEvent(K_AUX5, back ? 1 : 0)
        }
        if left != joyLeftDown {
            joyLeftDown = left
            IOS_KeyEvent(K_AUX6, left ? 1 : 0)
        }
        if right != joyRightDown {
            joyRightDown = right
            IOS_KeyEvent(K_AUX7, right ? 1 : 0)
        }
    }

    // MARK: - Button Touch Tracking

    /// Checks if a touch began on an action button. If so, sends key DOWN,
    /// stores the touch→button mapping, and returns true.
    private func handleButtonTouchBegan(_ touch: UITouch) -> Bool {
        let point = touch.location(in: self)
        for button in actionButtons + menuNavButtons where !button.isHidden {
            if button.frame.contains(point) {
                IOS_KeyEvent(button.keyCode, 1)
                button.isHighlighted = true
                buttonTouches[ObjectIdentifier(touch)] = button
                return true
            }
        }
        return false
    }

    /// Releases the button associated with this touch (if any),
    /// regardless of where the finger currently is.
    private func handleButtonTouchEnded(_ touch: UITouch) {
        let id = ObjectIdentifier(touch)
        if let button = buttonTouches[id] {
            IOS_KeyEvent(button.keyCode, 0)
            button.isHighlighted = false
            buttonTouches.removeValue(forKey: id)
        }
    }
}

// MARK: - Action Button

private class ActionButton: UIView {
    let keyCode: Int32
    private let label = UILabel()

    var isHighlighted: Bool = false {
        didSet {
            backgroundColor = isHighlighted
                ? UIColor(white: 0.4, alpha: 0.8)
                : UIColor(white: 0.2, alpha: 0.6)
        }
    }

    init(title: String, keyCode: Int32, fontSize: CGFloat = 15) {
        self.keyCode = keyCode
        super.init(frame: .zero)

        backgroundColor = UIColor(white: 0.2, alpha: 0.6)
        layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.borderWidth = 1.5

        label.text = title
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: fontSize)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isUserInteractionEnabled = false /* Parent handles touches */
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
