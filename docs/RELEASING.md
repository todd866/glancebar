# Release checklist

Glancebar does not currently claim a published binary release. This checklist creates
a candidate suitable for distribution outside the Mac App Store. It requires an Apple
Developer account, a `Developer ID Application` certificate, and notary credentials.

1. Start from a clean checkout and confirm `CFBundleShortVersionString` and
   `CFBundleVersion` in `Info.plist` are the intended release values. The marketing
   version is `1.1.0` and the monotonically increasing build number is `2` for this
   candidate.

2. Run the sanitizer tests, then build Universal 2 with the hardened runtime, an
   explicitly selected identity, and a trusted timestamp:

   ```bash
   GLANCEBAR_TEST_SANITIZERS=1 ./tests.sh
   GLANCEBAR_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
     GLANCEBAR_TIMESTAMP=1 \
     ./build.sh
   ```

   `build.sh` never discovers or chooses an identity automatically. Without the
   environment variable it uses an ad-hoc signature intended for local builds.

3. Verify the candidate before packaging it:

   ```bash
   codesign --verify --strict --verbose=2 build/Glancebar.app
   codesign -dvv build/Glancebar.app
   lipo -archs build/Glancebar.app/Contents/MacOS/Glancebar
   spctl --assess --type execute --verbose=2 build/Glancebar.app
   ```

   Before notarization, `spctl` may report that the otherwise valid Developer ID build
   is not notarized. The architecture output must contain both `arm64` and `x86_64`.

4. Package the app without altering its signature:

   ```bash
   mkdir -p dist
   ditto -c -k --sequesterRsrc --keepParent \
     build/Glancebar.app dist/Glancebar-1.1.0.zip
   ```

5. Store a notarytool profile once (the command prompts for the app-specific password),
   then submit the archive. After acceptance, staple the ticket to the app and recreate
   the archive so it contains the stapled app:

   ```bash
   xcrun notarytool store-credentials GLANCEBAR_NOTARY \
     --apple-id "release@example.com" --team-id TEAMID
   xcrun notarytool submit dist/Glancebar-1.1.0.zip \
     --keychain-profile GLANCEBAR_NOTARY --wait
   xcrun stapler staple build/Glancebar.app
   xcrun stapler validate build/Glancebar.app
   ditto -c -k --sequesterRsrc --keepParent \
     build/Glancebar.app dist/Glancebar-1.1.0.zip
   spctl --assess --type execute --verbose=2 build/Glancebar.app
   ```

6. Record a SHA-256 digest alongside the candidate and test the archive on a separate
   macOS 13-or-newer account before publishing anything:

   ```bash
   shasum -a 256 dist/Glancebar-1.1.0.zip
   ```

Do not publish the OAuth token, notary credentials, Keychain exports, or signing
certificate private keys. Signing Glancebar does not authorize its Claude integration:
that opt-in path invokes Apple's `/usr/bin/security`, and Keychain evaluates that Apple
tool rather than the app's signature.
