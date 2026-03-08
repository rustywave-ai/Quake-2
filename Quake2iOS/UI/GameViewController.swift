/*
 * GameViewController.swift
 * Hosts the MTKView and drives the Quake 2 game loop via CADisplayLink
 */

import UIKit
import MetalKit
import QuartzCore

class GameViewController: UIViewController {

    private var metalView: MTKView!
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var engineInitialized = false

    private var touchControlsView: TouchControlsView?
    private var overlayWindow: UIWindow?
    private var controllerManager: GameControllerManager!

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupMetalView()

        /* touchControlsView is created in setupOverlayWindow once
           the overlay window's scene is available. */

        setupControllerManager()
        observeAppLifecycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        /* Create the overlay window here — view.window.windowScene is
           only available after the view is in the window hierarchy. */
        if overlayWindow == nil {
            setupOverlayWindow()
        }

        /* Initialize engine AFTER the view is laid out so the
           CAMetalLayer has a valid drawableSize (non-zero). */
        guard !engineInitialized else { return }
        metalView.layoutIfNeeded()
        initializeEngine()
        startGameLoop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayWindow?.frame = UIScreen.main.bounds
    }

    // MARK: - Metal View Setup

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.framebufferOnly = true
        metalView.isPaused = true /* We drive rendering via CADisplayLink */
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60

        view.addSubview(metalView)
    }

    // MARK: - Touch Controls

    private func setupOverlayWindow() {
        /* Use a separate UIWindow so touch controls composite above Metal.
           CAMetalLayer drawables override normal UIView compositing,
           so a higher-level window is the reliable solution.
           iOS 13+ requires a windowScene for the window to be visible. */
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else {
            NSLog("Quake2 ERROR: No UIWindowScene found — cannot create overlay window!")
            return
        }


        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .statusBar + 1
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = true
        overlay.isHidden = false

        let overlayVC = UIViewController()
        overlayVC.view.backgroundColor = .clear
        overlay.rootViewController = overlayVC

        overlay.makeKeyAndVisible()
        overlay.layoutIfNeeded()

        /* Create touchControlsView fresh inside the overlay window context.
           Moving views between windows can cause rendering issues. */
        let controls = TouchControlsView(frame: overlayVC.view.bounds)
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayVC.view.addSubview(controls)
        touchControlsView = controls

        overlayWindow = overlay



    }

    // MARK: - Controller Manager

    private func setupControllerManager() {
        controllerManager = GameControllerManager()
        controllerManager.onControllerConnected = { [weak self] in
            self?.touchControlsView?.isHidden = true
        }
        controllerManager.onControllerDisconnected = { [weak self] in
            self?.touchControlsView?.isHidden = false
        }
    }

    // MARK: - Engine Initialization

    private func initializeEngine() {
        guard let metalLayer = metalView.layer as? CAMetalLayer else {
            fatalError("MTKView layer is not CAMetalLayer")
        }

        /* Ensure the layer has the correct content scale and drawable size
           before passing it to the C renderer. */
        metalLayer.contentsScale = UIScreen.main.nativeScale
        let bounds = metalLayer.bounds.size
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)

        /* Pass the Metal layer to the renderer */
        IOS_SetMetalLayer(Unmanaged.passUnretained(metalLayer).toOpaque())

        /* Set up paths */
        let basePath = Bundle.main.resourcePath!
        let savePath = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first!

        /* Update video size — use POINT dimensions (not pixels).
           Q2's HUD/menu code positions elements relative to viddef, so
           point dimensions give properly sized characters and icons.
           Metal handles upscaling to actual pixel resolution. */
        let screenSize = UIScreen.main.bounds.size
        let pointWidth = Int(max(screenSize.width, screenSize.height))
        let pointHeight = Int(min(screenSize.width, screenSize.height))
        IOS_SetVideoSize(Int32(pointWidth), Int32(pointHeight))

        /* Initialize the Quake 2 engine */
        Quake2_Init(basePath, savePath)
        engineInitialized = true

        /* Adjust FOV for widescreen — Q2 default 90 is for 4:3.
         * Scale horizontally: fov = 2*atan(tan(90/2) * aspect/1.333) */
        let aspect = Float(pointWidth) / Float(pointHeight)
        if aspect > 1.5 { /* wider than 3:2 */
            let baseFov: Float = 90.0
            let baseAspect: Float = 4.0 / 3.0
            let halfRad = baseFov * 0.5 * .pi / 180.0
            let newHalf = atan(tan(halfRad) * aspect / baseAspect)
            let newFov = Int(newHalf * 2.0 * 180.0 / .pi)
            Quake2_SetCvar("fov", "\(min(newFov, 120))")
        }
    }

    // MARK: - Game Loop

    private func startGameLoop() {
        displayLink = CADisplayLink(target: self, selector: #selector(gameFrame))
        displayLink?.preferredFramesPerSecond = 60
        displayLink?.add(to: .main, forMode: .common)
        lastTimestamp = CACurrentMediaTime()
    }

    @objc private func gameFrame(_ link: CADisplayLink) {
        guard engineInitialized else { return }

        let now = link.timestamp
        var msec = Int32((now - lastTimestamp) * 1000.0)
        lastTimestamp = now

        /* Clamp frame time to avoid spiral of death */
        if msec < 1 { msec = 1 }
        if msec > 100 { msec = 100 }

        /* Apply controller input if connected */
        controllerManager.pollInput()

        /* Apply continuous look input from touch joystick */
        touchControlsView?.applyLookInput()

        Quake2_Frame(msec)

        /* Update touch controls state (show game buttons once a game starts) */
        touchControlsView?.updateGameState()
    }

    // MARK: - App Lifecycle (pause/resume)

    private var isPaused = false

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: .quake2Pause, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: .quake2Resume, object: nil
        )
    }

    @objc private func appWillResignActive() {
        guard engineInitialized else { return }
        isPaused = true
        displayLink?.isPaused = true
        Quake2_Pause()
    }

    @objc private func appDidBecomeActive() {
        guard engineInitialized else { return }
        isPaused = false
        displayLink?.isPaused = false
        lastTimestamp = CACurrentMediaTime()
        /* Don't auto-resume — let the user resume via the menu/gear button.
           This prevents the game from unpausing in the background. */
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        displayLink?.invalidate()
        overlayWindow?.isHidden = true
        overlayWindow = nil
        NotificationCenter.default.removeObserver(self)
        if engineInitialized {
            Quake2_Shutdown()
        }
    }
}
