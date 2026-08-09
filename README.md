# The iOS app

A native SwiftUI client for a [Broadside](https://git.thebytes.net/broadside/broadside)
server. It talks to the same HTTP API that n8n or a shell script would, so it is
a first-party client rather than a privileged one, and anything it can do is
something you could do with `curl`.

Broadside is three repositories: **src** for the server, **app** for this, and
**docker** for running it. Clone them side by side and the paths in each
repository's documentation line up.

## Opening it

```bash
open app/Broadside.xcodeproj
```

There are no dependencies to fetch and no package manager to run. Set your team
under Signing & Capabilities and it builds.

| | |
|---|---|
| Minimum iOS | 18.0 |
| Swift | 6, strict concurrency |
| Dependencies | none |
| Bundle identifier | `net.thebytes.broadside` |

Change the bundle identifier before submitting, or App Store Connect will refuse
a name that belongs to somebody else.

## How it connects

There is no account to create in the app. On first launch it asks for two
things:

- **Your site's address.** The one you visit to read your own blog. A server on
  your own network can be given as an address and port, such as
  `192.168.1.50:5555`.
- **An API token.** Sign in to your site, open Site Settings, then the API tab,
  and create one. It is shown once.

The address is checked against the server before either is kept, so a typo is a
message on that screen rather than an app where every subsequent tab is broken.

The token goes in the Keychain, accessible after first unlock and marked
this-device-only so a restored backup does not carry your ability to publish
onto a different phone. The address goes in `UserDefaults`, where it is not a
secret and does not have to be typed again after a reinstall.

### Plain HTTP

`Info.plist` sets `NSAllowsLocalNetworking`, which permits unencrypted requests
to local network addresses and `.local` names, and nothing else. A server on
your house network works over `http://`. A server on the public internet has to
be `https://`, which a reverse proxy in front of Broadside is already doing.

This is the narrow exception Apple documents for exactly this case. It is
deliberately not `NSAllowsArbitraryLoads`, which permits plain HTTP everywhere
and has to be justified in writing at review.

## What is in here

```
app/
├── Broadside.xcodeproj
├── Support/Info.plist
├── Broadside/
│   ├── Models/         Post, Block, and the markdown round trip
│   ├── Networking/     the API client, errors, and the background uploader
│   ├── Storage/        Keychain and the account
│   └── Features/       the screens
└── BroadsideTests/
```

The Xcode project uses a synchronized file group, so a new Swift file anywhere
under `Broadside/` is picked up with no project file to edit and nothing to
merge when two branches both add a file.

## Two things worth knowing before changing anything

**The markdown round trip is a pair.** `Models/BlockDocument.swift` and
`internal/server/static/js/editor.js` parse and serialize posts to the same
rules, and they have to agree. A post written on a phone, opened in a browser,
and saved must come back byte for byte, or somebody who works on both gets a
rewritten file every time they switch and real changes buried in the noise.
`BlockDocumentTests` pins that with round trips over the constructs most likely
to drift. Adding a block type means adding it here, in the web editor, and in
`internal/render` — all three, or it will parse in one place and vanish in
another.

**Uploads go through the system, not through the app.** `MediaUploader` uses a
background `URLSession`, which is why the multipart body is written to a file
rather than built in memory and why results arrive through a delegate. A
stacked astrophotography frame is several hundred megabytes and takes minutes;
nobody watches a progress bar for minutes, and a foreground transfer dies the
moment they switch apps. That is also why `PickedFile` imports from the photo
library as a file rather than as `Data`: a 300MB image decoded into memory is a
process the system will terminate.

## Tests

```bash
cd app
xcodebuild test -project Broadside.xcodeproj -scheme Broadside \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`BlockDocumentTests` is pure logic and always runs. `LiveServerTests` exercises
the client against a real server and skips itself unless pointed at one:

```bash
xcrun simctl spawn booted launchctl setenv BROADSIDE_TEST_URL http://127.0.0.1:5561
xcrun simctl spawn booted launchctl setenv BROADSIDE_TEST_TOKEN <token>
```

Those have to be set in the simulator's own environment. `xcodebuild` does not
pass the shell's environment to a process running in the simulator, so setting
them on the command line leaves the live tests skipped — and a skipped run still
exits zero. The suite reports "skipped" rather than "passed" for exactly that
reason.
