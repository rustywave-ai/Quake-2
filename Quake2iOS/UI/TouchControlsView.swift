/*
 * TouchControlsView.swift
 * Transparent overlay for touch input — virtual joystick + look + action buttons
 */

import UIKit

class TouchControlsView: UIView {

    /* Quake key codes (from game/q_shared.h) */
    private let K_ENTER: Int32 = 13       /* Select */
    private let K_ESCAPE: Int32 = 27      /* Menu */
    private let K_SPACE: Int32 = 32       /* Jump */
    private let K_UPARROW: Int32 = 128
    private let K_DOWNARROW: Int32 = 129
    private let K_CTRL: Int32 = 157       /* Crouch — K_CTRL */
    private let K_MOUSE1: Int32 = 179     /* Fire */
    private let K_MWHEELUP: Int32 = 185   /* Next weapon */
    private let K_MWHEELDOWN: Int32 = 186 /* Prev weapon */

    /* Sub-views */
    private let joystick = VirtualJoystick()
    private var actionButtons: [ActionButton] = []

    /* Game state — action buttons hidden until a real game starts */
    private(set) var gameControlsVisible = false {
        didSet {
            for btn in actionButtons { btn.isHidden = !gameControlsVisible }
        }
    }

    /* Look tracking */
    private var lookTouch: UITouch?
    private var lookPrevPoint = CGPoint.zero
    private let lookSensitivity: Float = 0.25

    /* Joystick zone: left 35% of screen */
    private var joystickZoneWidth: CGFloat { bounds.width * 0.35 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear

        addSubview(joystick)
        setupButtons()

        /* Start with action buttons hidden */
        for btn in actionButtons { btn.isHidden = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        joystick.frame = bounds
        layoutButtons()
    }

    /// Called each frame to sync game controls visibility with engine state.
    /// Action buttons only appear when the player is in an actual game
    /// (not during attract/demo loop or disconnected state).
    func updateGameState() {
        let inGame = IOS_IsInGame() != 0
        if inGame != gameControlsVisible {
            gameControlsVisible = inGame
        }
    }

    // MARK: - Buttons

    private func setupButtons() {
        let buttonDefs: [(String, Int32)] = [
            ("Fire", K_MOUSE1),
            ("Jump", K_SPACE),
            ("Crouch", K_CTRL),
            ("▲", K_MWHEELUP),
            ("▼", K_MWHEELDOWN),
        ]
        for (title, key) in buttonDefs {
            let btn = ActionButton(title: title, keyCode: key)
            addSubview(btn)
            actionButtons.append(btn)
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
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)

            /* When game controls are visible, check action buttons first */
            if gameControlsVisible && handleButtonTouch(touch, began: true) {
                continue
            }

            /* When menu is active, taps navigate the menu */
            if IOS_IsMenuActive() != 0 {
                handleMenuTouch(at: point)
                continue
            }

            /* Before a game starts, any tap opens the menu */
            if !gameControlsVisible {
                sendKeyTap(K_ESCAPE)
                continue
            }

            /* In-game touch zones */
            if point.x < joystickZoneWidth {
                /* Left zone — joystick */
                joystick.touchBegan(at: point)
                updateJoystickInput()
            } else {
                /* Right zone — look */
                if lookTouch == nil {
                    lookTouch = touch
                    lookPrevPoint = point
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard gameControlsVisible else { return }
        for touch in touches {
            let point = touch.location(in: self)

            if joystick.isActive && touch != lookTouch {
                joystick.touchMoved(to: point)
                updateJoystickInput()
            }

            if touch === lookTouch {
                let dx = Float(point.x - lookPrevPoint.x) * lookSensitivity
                let dy = Float(point.y - lookPrevPoint.y) * lookSensitivity
                IOS_SetLookInput(dx, dy)
                lookPrevPoint = point
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if gameControlsVisible { handleButtonTouch(touch, began: false) }

            if touch === lookTouch {
                lookTouch = nil
            } else if joystick.isActive {
                joystick.touchEnded()
                updateJoystickInput()
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

    // MARK: - Helpers

    private func updateJoystickInput() {
        IOS_SetJoystickInput(joystick.yAxis, joystick.xAxis)
    }

    @discardableResult
    private func handleButtonTouch(_ touch: UITouch, began: Bool) -> Bool {
        let point = touch.location(in: self)
        for button in actionButtons where !button.isHidden {
            if button.frame.insetBy(dx: -10, dy: -10).contains(point) {
                IOS_KeyEvent(button.keyCode, began ? 1 : 0)
                button.isHighlighted = began
                return true
            }
        }
        return false
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

    init(title: String, keyCode: Int32) {
        self.keyCode = keyCode
        super.init(frame: .zero)

        backgroundColor = UIColor(white: 0.2, alpha: 0.6)
        layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        layer.borderWidth = 1.5

        label.text = title
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 15)
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
