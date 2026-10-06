# Mainbrella for iOS

A native SwiftUI human cockpit for cloud agents. Supports iPhone and iPad, iOS 17+.

Open `Mainbrella.xcodeproj`, choose the Mainbrella scheme, and run on an iPhone or iPad simulator. For a physical device, select your development team in Signing & Capabilities. The app opens account connection when no API key is saved. It displays only authenticated account data and does not create or stop cloud machines.

## Current workflows

- **Activity:** real managed executions, grouped into working and finished. Failed executions retain their actual status.
- **Projects:** live running containers, exact generation identity, and lease expiry.
- **Previews:** create a protected preview for an already running server port, inspect it in a nonpersistent WKWebView, and list/revoke existing grants. URLs are issued once and kept in memory.
- **Fix this:** capture the visible web viewport, draw with a finger or Apple Pencil, and add an instruction. Uploads a marked JPEG and JSON report to the selected generation's `/workspace/inbox`.
- **Account:** connect using an existing account API key. The key is stored in the device-only Keychain; the API address defaults to `https://api.mainbrella.com/`. Account links use `https://mainbrella.com/`. State loads on launch or connection, and updates on pull-to-refresh. There are no polling timers.
- **iPad:** sidebar, activity, and an inspector when a preview is open in landscape; native tabs in compact layouts.

Use **Account → Create an API key** to obtain a key from the web account. No backend credentials are bundled. Apple login in the sibling backend currently targets the Groupicorn bundle ID, so this app uses the supported account API key flow.

## Backend contract

Implemented against `../backend/API.md` and the route handlers:

| Workflow | API |
| --- | --- |
| Workspaces | `GET /containers` |
| Working / Finished | `GET /containers/executions?id=…&createdAt=…` |
| Grants | `GET /containers/previews?id=…&createdAt=…` |
| Open preview | `POST /containers/previews?id=…&createdAt=…` with port and 900-second TTL |
| Revoke | `DELETE /containers/previews?id=…&createdAt=…&previewId=…` |
| Inbox directory | `POST /containers/files/mkdir?id=…&createdAt=…` |
| Feedback | `PUT /containers/files?id=…&createdAt=…&path=…` |

All requests use Bearer authentication. Generation strings are preserved exactly. Preview creation is never automatically retried: a lost response may have created a grant, so refresh the grant list and revoke the outstanding grant before another issuance. Existing metadata does not contain a recoverable URL.

Feedback uploads use a stable UUID for a retry within the editor. The JPEG is uploaded first and `feedback-<UUID>.json` last as the completion marker. Agents should watch JSON files, then read the referenced JPEG. The report includes the instruction, URL, capture timestamp, container generation, native webview dimensions, display scale, safe-area insets, orientation, OS version, and bounded JavaScript errors. Uploads follow the API's 1 MiB file limit. Uploaded feedback is ephemeral and disappears when the workspace stops. Page diagnostics and URLs can contain application data; reports remain in the selected workspace.

This version **does not dispatch an agent automatically**. There is no agent approval queue, device push registration, or agent-message endpoint in the current backend. Approval controls are absent. Screenshot feedback is a file handoff; it does not claim that an agent has resumed. Future live updates must use WebSockets or Apple push notifications. Network tracing, touch replay, voice/camera/share extensions, Live Activities, and Watch support remain future work.

## Development

There are no third-party runtime dependencies. `project.yml` is the XcodeGen source, and the generated Xcode project is checked in. Run `xcodegen generate` after editing project configuration.

```sh
xcodebuild -project Mainbrella.xcodeproj -scheme Mainbrella \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' test
```

Tests cover request identity, one-time preview decoding, ambiguous issuance without automatic retries, upload limits, authenticated connection state, disconnect cleanup, and the account gate on iPhone and iPad. No tests contact production. Account-gate UI tests require a simulator without a saved API key.

The existing `1024.png` is used for the app icon; the original file is preserved.
