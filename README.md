# Element Remote

Native iPhone/iPad OSC remote for ETC Element and Eos-family consoles, with an offline sample-show Test Mode. Independently developed; not affiliated with ETC.

## Build

The **Build and upload to TestFlight** GitHub Actions workflow validates the web and OSC code, builds on a macOS runner, signs, and uploads to TestFlight. It does not submit to public App Review. Apple signing material is supplied only through the encrypted `ELEMENT_SIGNING_BUNDLE` repository secret.

For local web checks: `npm ci`, `npm test`, `npm run build`. For OSC checks: `swift test --package-path native/OSCWire`. The Xcode project is `ios/App/App.xcodeproj`.

See LICENSE for the original project's MIT license.
