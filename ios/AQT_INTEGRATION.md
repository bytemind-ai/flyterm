# iOS AQT Client FFI Integration

## Build

Build the xcframework for all iOS targets (device + simulator):

```bash
cd ios && ./build-aqt-xcframework.sh
```

This requires:
- Rust toolchain (rustup)
- iOS deployment targets: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`
- Xcode command-line tools (for lipo, xcodebuild)

Output: `ios/Frameworks/AqtClientFfi.xcframework`

## Xcode setup (one-time)

After building the xcframework, add it to the Runner target:

1. Open `ios/Runner.xcworkspace` in Xcode (not the .xcodeproj)
2. Select Runner target → General tab
3. Scroll to "Frameworks, Libraries, and Embedded Content"
4. Click **+** → Add Other → Add Files
5. Navigate to and select `ios/Frameworks/AqtClientFfi.xcframework`
6. Set embedding to **Do Not Embed** (static library; only device needs runtime linking)

Alternative: Use Xcode Build Settings via `xcconfig`:

1. In Xcode, select Runner target → Build Settings
2. Add to "Framework Search Paths":
   ```
   $(SRCROOT)/Frameworks
   ```
3. Add to "Other Linker Flags":
   ```
   -framework AqtClientFfi -lc++
   ```

## Dynamic Library Loading (Dart)

In Dart/Flutter, load the static library via FFI:

```dart
import 'dart:ffi';

// iOS: static library; DynamicLibrary.process() finds symbols at runtime
final dylib = DynamicLibrary.process();

// Load AQT client functions
typedef init_aqt_client = void Function();
final initAqtClient = dylib.lookupFunction<init_aqt_client, void Function()>('init_aqt_client');
```

## Notes

- **iOS**: Static library (`.a` + xcframework) linked at build time
- **Android**: Dynamic library (`.so`) linked at runtime
- The `.xcframework` contains both device (arm64) and simulator (arm64 + x86_64) slices
- Build artifacts (`ios/Frameworks/AqtClientFfi.xcframework`, `rust/target/lipo-ios-sim/`) are in `.gitignore` and should not be committed
