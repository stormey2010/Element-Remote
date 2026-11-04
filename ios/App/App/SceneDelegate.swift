import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UIGestureRecognizerDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = UIHostingController(rootView: NativeRemoteView())
        // Observe taps without consuming buttons, sliders, or SwiftUI gestures.
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        window?.addGestureRecognizer(tap)
        window?.makeKeyAndVisible()


    }

    @objc private func dismissKeyboard() { window?.endEditing(true) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Tapping within any text editor should keep editing and cursor selection working.
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {

    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {

    }
}
