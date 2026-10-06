# Mainbrella for iOS

A native SwiftUI human cockpit for cloud agents. Supports iPhone and iPad, iOS 17+.

Open `Mainbrella.xcodeproj`, choose the Mainbrella scheme, and run on an iPhone or iPad simulator. For a physical device, select your development team in Signing & Capabilities. The app opens account connection when no API key is saved. It displays only authenticated account data and does not create or stop cloud machines.

## Current workflows

- **Activity:** real managed executions grouped into Needs review, Working, and Finished. Open an execution to inspect stdout, stderr, status, and exit code, or copy output to the iPhone clipboard. Lists update from the account activity WebSocket. Open details reload on execution status changes, reconnection, or a manual refresh; stdout is not streamed per chunk.
- **Projects:** live running containers, exact generation identity, and lease expiry.
- **Previews:** create a protected preview for an already running server port, inspect it in a nonpersistent WKWebView, and list/revoke existing grants. URLs are issued once and kept in memory.
- **Fix this:** capture the visible web viewport, draw with a finger or Apple Pencil, and add an instruction. Uploads a marked JPEG and JSON report to the selected generation's `/workspace/inbox`.
- **Send to workspace:** send an instruction with text, a link, clipboard content using the system Paste button, or a photo/screenshot from the native photo picker. Images are downsampled before encoding. Uploads the attachment first and `message-<UUID>.json` last; retries reuse the message identity.
- **Account:** connect using an existing account API key. The key is stored in the device-only Keychain; the API address defaults to `https://api.mainbrella.com/`. Account links use `https://mainbrella.com/`. A Bearer-authenticated WebSocket subscribes while the app is active. Its `ready` frame triggers a snapshot; `changed` frames refresh only the affected workspace resource. Returning to the foreground or reconnecting repairs missed changes with a fresh snapshot. Pull-to-refresh remains available. There are no polling timers.
- **iPad:** sidebar, activity, and an inspector when a preview is open in landscape; native tabs in compact layouts.

Use **Account → Create an API key** to obtain a key from the web account. No backend credentials are bundled. Apple login in the sibling backend currently targets the Groupicorn bundle ID, so this app uses the supported account API key flow.

## Backend contract

Implemented against `../backend/API.md` and the route handlers:

| Workflow | API |
| --- | --- |
| Live availability | `GET /capabilities` |
| Live activity | `GET /containers/activity` (WebSocket upgrade) |
| Workspaces | `GET /containers` |
| Working / Finished | `GET /containers/executions?id=…&createdAt=…` |
| Execution output | `GET /containers/executions/<execution-id>?id=…&createdAt=…` |
| Grants | `GET /containers/previews?id=…&createdAt=…` |
| Open preview | `POST /containers/previews?id=…&createdAt=…` with port and 900-second TTL |
| Revoke | `DELETE /containers/previews?id=…&createdAt=…&previewId=…` |
| Inbox directory | `POST /containers/files/mkdir?id=…&createdAt=…` |
| Feedback | `PUT /containers/files?id=…&createdAt=…&path=…` |

All requests use Bearer authentication, including the WebSocket handshake; credentials never go in the socket URL. Generation strings are preserved exactly. Activity frames are invalidation hints, not durable history: changes received during a read are retained, bursts are coalesced, and stale generation hints are ignored. Container lifecycle hints trigger a full snapshot; execution and preview hints refresh the matching resource. Reconnects use exponential backoff with jitter, transport heartbeats detect lost connections, and backgrounding cancels the socket. Rejected credentials stop reconnection and direct the user to Account. Unsupported servers display an explicit manual-refresh state. Revoked grants or stopped workspaces dismiss an open preview. Preview creation is never automatically retried: a lost response may have created a grant, so refresh the grant list and revoke the outstanding grant before another issuance. Existing metadata does not contain a recoverable URL.

Feedback uploads use a stable UUID for a retry within the editor. The JPEG is uploaded first and `feedback-<UUID>.json` last as the completion marker. Agents should consume JSON files, then read the referenced JPEG. The report includes the instruction, URL, capture timestamp, container generation, native webview dimensions, display scale, safe-area insets, orientation, OS version, JavaScript layout/visual viewport and scroll position, and bounded errors, warnings, and fetch/XHR failures. Diagnostics reset on navigation; request bodies and headers are not recorded. This captures page JavaScript network failures, not a full native network trace. Uploads follow the API's 1 MiB file limit. Uploaded feedback is ephemeral and disappears when the workspace stops. Page diagnostics and URLs can contain application data; reports remain in the selected workspace.

Text/photo messages use the same completion pattern with `message-<UUID>.json`. Each message includes `version`, `createdAt`, `workspaceID`, exact `generation`, `source`, `instruction`, `text`, and an optional `attachment` filename relative to `/workspace/inbox`. Both handoffs save files; they do not launch processes or claim an agent has resumed.

This version **does not dispatch an agent automatically**. The production activity WebSocket was verified on October 6, 2026. The terminal WebSocket still requires a browser session cookie. There is no agent approval queue, Mainbrella device push registration, or agent-message endpoint. Live updates work in the foreground; background alerts and approvals need a backend push/approval contract. Network tracing, touch replay, voice/camera/share extensions, Live Activities, and Watch support remain future work.

## Development

There are no third-party runtime dependencies. `project.yml` is the XcodeGen source, and the generated Xcode project is checked in. Run `xcodegen generate` after editing project configuration.

```sh
xcodebuild -project Mainbrella.xcodeproj -scheme Mainbrella \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' test
```

Tests cover request identity, one-time preview decoding, ambiguous issuance without automatic retries, upload limits, execution decoding, attachment-before-metadata ordering, authenticated connection state, disconnect cleanup, WebSocket authentication, reconnection, cancellation, capability fallback, generation filtering, scoped reads, invalidations during an in-flight read, burst coalescing, revoked preview dismissal, and the account gate on iPhone and iPad. Tests skip production checks unless explicitly supplied credentials by the smoke script. Account-gate UI tests require a simulator without a saved API key.

An explicit production smoke check uses the actual Swift client and reads the key from `../backend/.env` without bundling it. It creates **one Lite workspace**, checks file handoff/readback, retained execution output, and a protected preview, then stops only the generation it created. It attaches the production WebSocket before creating the workspace, verifies lifecycle/execution/preview hints, fetches execution state only after an event, and checks a reconnect snapshot. It never polls. Creation identity is saved in a temporary recovery checkpoint before work starts. If creation or cleanup fails, use that checkpoint to reconcile the same idempotency key/generation before another run.

```sh
swiftc Mainbrella/APIClient.swift Mainbrella/Models.swift scripts/ProductionSmoke.swift \
  -o /tmp/mainbrella-production-smoke
/tmp/mainbrella-production-smoke ../backend/.env
# Add --ui to exercise connection, text handoff, preview, annotation, and screenshot upload.
# Add --ui --ipad for the iPad simulator. Each invocation creates one temporary workspace.
# Use --ui --simulator-id=<UUID> to select an isolated simulator with no saved account.
```

Production UI checks require an initially disconnected simulator and remove the saved test key afterward. They create an execution after the app connects and verify that its row and open output update automatically, then exercise text handoff, preview, annotation, and screenshot upload. The remaining UI tests run without production credentials. Neither the production test script nor its credentials are part of the app target.

The existing `1024.png` is used for the app icon; the original file is preserved.
