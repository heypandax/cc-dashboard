// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cc-dashboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CCDashboard", targets: ["CCDashboard"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CCDashboard",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FirebaseAnalytics",   package: "firebase-ios-sdk"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk")
            ],
            path: "Sources/CCDashboard",
            linkerSettings: [
                // SwiftPM 默认不给 executable 加 bundle 内 Frameworks/ 的 rpath。
                // 没这条 dyld 找不到 @rpath/Sparkle.framework,app 启动即崩。
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "CCDashboardTests",
            dependencies: [
                "CCDashboard",
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ],
            path: "Tests/CCDashboardTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
