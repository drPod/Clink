# Bump Demo

Two iPhones running the app discover one another, exchange Nearby Interaction
tokens, and turn green with a haptic response when they come within about 25 cm.
Each phone can connect Instagram, LinkedIn and X. When two phones meet, the
server compares every network both phones have connected:

| Network | Sign-in | Compared list |
|---|---|---|
| Instagram | Unipile Hosted Auth | accounts both people follow |
| LinkedIn | Unipile Hosted Auth | mutual connections |
| X | X OAuth 2.0 with PKCE (proves the account) | accounts both people follow, from twitterapi.io |

## Run on two iPhones

1. Use two iPhones that support UWB distance measurement. Keep both apps in the
   foreground. The app checks capability at runtime and displays an error on
   unsupported devices.
2. Connect each phone to the Mac, unlock it, trust the computer, and enable
   Developer Mode if prompted.
3. Open `BumpDemo.xcodeproj`. In Signing & Capabilities, select your Personal
   Team or development team and turn on automatic signing. Change the bundle ID
   if Xcode says it is taken.
4. Select the first phone as the run destination and press Run. Repeat for the
   second phone. Allow Local Network and Nearby Interaction permissions on both.
5. Connect the same network on both phones, then bring the phones close. Both should
   turn green and vibrate, followed by the common following list. Tap **Try
   again** to repeat. If discovery stops, tap **Restart pairing** on both.

The phones may use different Apple Accounts. Xcode signs the app with the
developer team selected on each Mac and must provision its connected device.
You can build the same project on two Macs, one phone per Mac. The iPhone 18 Pro
running iOS 27 needs an Xcode installation with matching iOS 27 device support;
Xcode 26.6 on the first Mac reports a missing device image variant for it.

`project.yml` is the XcodeGen source. If the Xcode project needs regenerating,
run `xcodegen generate` from this directory.

The API lives in `server/`. It requires an application-scoped Unipile v2 API key
in `UNIPILE_V2_API_KEY` on the server for Instagram and LinkedIn.

X is enabled when the server also has `X_CLIENT_ID` and `TWITTERAPI_IO_KEY`
(plus `X_CLIENT_SECRET` for a confidential X app). In the X developer console,
enable OAuth 2.0 user authentication for the app and register
`https://bump.40-160-146-47.sslip.io/v1/x/callback` as the callback URL. The
server requests only `users.read tweet.read`, uses the token once to read the
signed-in username, and does not store it.

Instagram sign-in in Unipile's web page can fail with "Captcha verification
failed". Use the page's UniLogin option from a desktop Chrome profile that is
signed in to Instagram; the phone picks up the account when the app returns to
the foreground. Its signing and data stay on the server;
the iOS app keeps only its own anonymous device token in Keychain. The server
stores complete following lists for one hour and honors Unipile rate limits.

For the VPS deployment, `server/deploy/` contains Docker Compose and Caddy
configuration. The running application copy is at `~/.local/share/bump-demo/app`, its
database at `~/.local/share/bump-demo/data/bump.db`, and its private environment
file at `~/.config/bump-demo/server.env`.
