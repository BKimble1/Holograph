# Deep-link integration

Holograph can only open an app that has told iPadOS how to be opened. That
means the *target* app must register either a **custom URL scheme** or a
**universal link**. There is no supported way for one app to launch another by
bundle identifier, and this launcher deliberately does not try.

Registering a scheme is enough to bring the target app to the foreground. You
only need `onOpenURL` if you also want the launcher to land on a particular
screen.

---

## 1. Schemes to register

| App        | Scheme              | Launch link the launcher should store |
| ---------- | ------------------- | ------------------------------------- |
| CoreCredit | `idler-corecredit`  | `idler-corecredit://launch`           |
| OffRent    | `idler-offrent`     | `idler-offrent://launch`              |
| Magshift   | `idler-magshift`    | `idler-magshift://launch`             |
| Turbid     | `idler-turbid`      | `idler-turbid://launch`               |

URL schemes are first-come, first-served on a device and are **not** namespaced
by Apple, so the `idler-` prefix matters: it keeps these from colliding with
another developer's `offrent://`.

---

## 2. Register the scheme in Xcode (GUI)

1. Open the target app's project.
2. Select the **app target** → **Info** tab.
3. Expand **URL Types** and press **+**.
4. Fill in:
   - **Identifier**: the app's bundle identifier, e.g. `com.idlery.offrent`
   - **URL Schemes**: `idler-offrent`
   - **Role**: `Editor`
5. Build and run once on the device so iPadOS records the registration.

That is the whole requirement. Tapping the tile in Holograph will now
foreground the app.

---

## 3. Register the scheme in `Info.plist` (ready-to-apply patch)

If the target app uses an explicit `Info.plist`, add this block inside the
top-level `<dict>`. Substitute the scheme and identifier per app.

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>CFBundleURLName</key>
        <string>com.idlery.offrent</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>idler-offrent</string>
        </array>
    </dict>
</array>
```

Per-app values:

| App        | `CFBundleURLName`      | `CFBundleURLSchemes` entry |
| ---------- | ---------------------- | -------------------------- |
| CoreCredit | `com.idlery.corecredit`| `idler-corecredit`         |
| OffRent    | `com.idlery.offrent`   | `idler-offrent`            |
| Magshift   | `com.idlery.magshift`  | `idler-magshift`           |
| Turbid     | `com.idlery.turbid`    | `idler-turbid`             |

> Replace `com.idlery.<app>` with the app's real bundle identifier if it differs.
> `CFBundleURLName` is only a label; the scheme is what matters.

### If the target app has no `Info.plist` file

Modern Xcode templates generate the `Info.plist` from build settings. You can
still add a URL type without creating a file — add this build setting to the app
target (Build Settings → **+** → *Add User-Defined Setting* is **not** needed;
use the Info tab as in section 2, which writes `INFOPLIST_KEY_…` entries or
creates the file for you).

If you prefer a file, in **Build Settings** set:

```
GENERATE_INFOPLIST_FILE = NO
INFOPLIST_FILE = <AppName>/Info.plist
```

then add the `CFBundleURLTypes` block above to that file.

---

## 4. Verify the registration

On the iPad, in Safari, type the scheme into the address bar:

```
idler-offrent://launch
```

Safari will ask to open the app. If it does, the launcher will work too. If
Safari says the address is invalid, the scheme is not registered — rebuild and
reinstall the target app.

You can also verify from a Mac against a booted simulator:

```bash
xcrun simctl openurl booted "idler-offrent://launch"
```

---

## 5. Optional: land on a specific screen

Registering the scheme foregrounds the app. To route to a screen, handle the URL
in SwiftUI:

```swift
import SwiftUI

@main
struct OffRentApp: App {
    @State private var route: Route?

    var body: some Scene {
        WindowGroup {
            RootView(route: $route)
                .onOpenURL { url in
                    guard url.scheme == "idler-offrent" else { return }
                    route = Route(url: url)
                }
        }
    }
}

/// `idler-offrent://launch` → .home
/// `idler-offrent://equipment/4821` → .equipment(id: "4821")
enum Route: Hashable {
    case home
    case equipment(id: String)
    case newInspection

    init?(url: URL) {
        // `host` carries the first path element for scheme URLs.
        let segments = ([url.host] + url.pathComponents.filter { $0 != "/" }).compactMap { $0 }
        switch segments.first {
        case "launch", nil:
            self = .home
        case "equipment":
            guard segments.count > 1 else { return nil }
            self = .equipment(id: segments[1])
        case "new-inspection":
            self = .newInspection
        default:
            return nil
        }
    }
}
```

If the app uses the UIKit lifecycle instead, implement:

```swift
func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url, url.scheme == "idler-offrent" else { return }
    // route on url
}
```

and, for a cold launch:

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    if let url = options.urlContexts.first?.url { /* route on url */ }
}
```

---

## 6. Universal links (alternative)

If an app already serves a website, a universal link works as the launch link
and degrades to the website when the app is not installed:

1. Add the **Associated Domains** capability with `applinks:example.com`.
2. Serve `https://example.com/.well-known/apple-app-site-association` (JSON, no
   extension, `Content-Type: application/json`, HTTPS, no redirects):

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["TEAMID.com.idlery.offrent"],
        "components": [{ "/": "/app/*" }]
      }
    ]
  }
}
```

3. Store `https://example.com/app/launch` as the launch link.

Universal links are more work but survive scheme collisions and give you a
graceful fallback for free.

---

## 7. How the launcher uses these links

- The launcher calls `UIApplication.open(_:)` and reports the system's actual
  result. It never calls `canOpenURL` on your schemes, so you do **not** need to
  add anything to *this* app's `LSApplicationQueriesSchemes`.
- If the open is refused — app not installed, scheme not registered — the
  launcher offers **Edit App**, **Open Fallback** (when one is configured) and
  **Cancel**.
- A good fallback is the App Store page (`https://apps.apple.com/app/idXXXXXXXXX`),
  a TestFlight invite link, or the product website. The fallback is never used as
  the primary launch link.

---

## 8. Status of these repositories

The four target apps (CoreCredit, OffRent, Magshift, Turbid) are not present in
this workspace, so nothing in them has been modified. The blocks in sections 3
and 5 are ready to apply as-is. After adding a scheme to an app, rebuild and
reinstall it on the iPad, then confirm with the Safari check in section 4.
