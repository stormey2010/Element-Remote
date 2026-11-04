// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "OSCWire", products: [.library(name: "OSCWire", targets: ["OSCWire"])], targets: [.target(name: "OSCWire"), .testTarget(name: "OSCWireTests", dependencies: ["OSCWire"])])
