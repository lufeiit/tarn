import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    SubscriptionLinkBridge.shared.receive(connectionOptions.urlContexts)
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    SubscriptionLinkBridge.shared.receive(URLContexts)
    super.scene(scene, openURLContexts: URLContexts)
  }
}
