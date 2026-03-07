/*
 * AppDelegate.swift
 * Quake 2 iOS application delegate
 */

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = MainMenuViewController()
        window?.makeKeyAndVisible()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        /* Pause game when backgrounding */
        NotificationCenter.default.post(name: .quake2Pause, object: nil)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .quake2Resume, object: nil)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        NSLog("Quake2: Memory warning — flushing unused textures")
        Quake2_MemoryWarning()
    }
}

extension Notification.Name {
    static let quake2Pause = Notification.Name("Quake2Pause")
    static let quake2Resume = Notification.Name("Quake2Resume")
}
