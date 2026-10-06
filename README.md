# Mainbrella for iOS

A native SwiftUI human cockpit for cloud agents. Supports iPhone and iPad, iOS 17+.

Open `Mainbrella.xcodeproj`, choose the Mainbrella scheme, and run on an iPhone or iPad simulator. For a physical device, select your development team in Signing & Capabilities. A fresh install opens a marketing welcome page after a brief logo splash. Get started opens native sign-in; a saved account goes straight to Activity. The welcome page introduces the cloud-agent direction from `../mac.plan2.md`, with handoff, persistent agent sessions, approvals, and completion alerts labeled as coming next. It displays only authenticated account data and does not create or stop cloud machines.

## Current workflows

- **Activity:** real managed executions grouped into Needs review, Working, and Finished. Open an execution to inspect stdout, stderr, status, and exit code, copy output to the iPhone clipboard, or share it through the native share sheet. Lists update from the account activity WebSocket. Open details reload on execution status changes, reconnection, or a manual refresh; stdout is not streamed per chunk.
- **Projects:** live running containers, exact generation identity, and lease expiry.
- **Previews:** create a protected preview for an already running server port, inspect it in a nonpersistent WKWebView, and list/revoke existing grants. URLs are issued once and kept in memory.
- **Fix this:** capture the visible web viewport, draw with a finger or Apple Pencil, and add an instruction. Uploads a marked JPEG and JSON report to the selected generation's `/workspace/inbox`.
- **Send to workspace:** send an instruction with text, a link, clipboard content using the system Paste button, a photo/screenshot, a native camera capture, or one file from Files. Camera access is requested only when tapped; denied access offers a Settings link. Camera controls appear only on devices with a camera. Photos are resized to at most 2048 pixels before encoding. Files (including PDFs, source files, and ZIPs) are transferred unchanged and must be at most 1 MiB; folders are rejected. Uploads the attachment first and `message-<UUID>.json` last. Unchanged retries keep identical metadata and attachment bytes; editing creates a new message identity. A stopped or replaced workspace disables sending.
- **Share to Mainbrella:** from Safari, Photos, or another app's share sheet, send a web link, text, or one image to an existing running workspace with an instruction. The extension reads the app's account credential from a shared, device-only Keychain group and keeps workspace choices current through the authenticated activity WebSocket. Replaced generations clear the selection. Photos are downsampled before decoding; unsupported attachments and oversized text are rejected without silently dropping content. Unchanged upload retries reuse the same completion filename and metadata. Sharing saves an inbox message and does not start an agent or create a workspace.
- **Account:** sign in with Google using the native Google Sign-In SDK, or continue with email and password. As on the web, a new email creates an account (passwords require at least 8 characters), and an existing email signs in. Account sessions are stored in the shared, device-only Keychain; the API address defaults to `https://api.mainbrella.com/`. Account links use `https://mainbrella.com/`. A Bearer-authenticated WebSocket subscribes while the app is active. Its `ready` frame triggers a snapshot; `changed` frames refresh only the affected workspace resource. Returning to the foreground or reconnecting repairs missed changes with a fresh snapshot. Pull-to-refresh remains available. There are no polling timers.
- **iPad:** sidebar, activity, and an inspector when a preview is open in landscape; native tabs in compact layouts.

Google sign-in uses the iOS OAuth client configured in `Mainbrella/Info.plist` and the existing web client as its server client ID. It exchanges the Google ID token at `POST /auth/google`; email uses `POST /auth/email`. Both endpoints issue the same 30-day `mainbrella_session` as the web. The app extracts the opaque session token and sends it as a Bearer credential to workspace APIs and the activity WebSocket. Session checks and sign-out use an explicit cookie on `/auth/me` and `/auth/logout`; automatic cookie storage is disabled. Sign-out revokes the server session and clears the shared Keychain credential, including the share extension. Expired sessions return to sign-in; an offline session check retains the saved credential. Signing in succeeds even without an active plan or workspace.

Existing saved API keys still work. **Use an API key** on the sign-in screen provides optional manual connection. No backend secrets are bundled. Apple login in the sibling backend currently targets the Groupicorn bundle ID.

## Backend contract

Implemented against `../backend/API.md` and the route handlers:

| Workflow | API |
| --- | --- |
| Google sign-in / account creation | `POST /auth/google` with Google ID token |
| Email sign-in / account creation | `POST /auth/email` with email and password |
| Restore account | `GET /auth/me` with session cookie |
| Sign out | `POST /auth/logout` with session cookie |
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

Workspace requests use Bearer authentication, including the WebSocket handshake; credentials never go in the socket URL. Generation strings are preserved exactly. Activity frames are invalidation hints, not durable history: changes received during a read are retained, bursts are coalesced, and stale generation hints are ignored. Container lifecycle hints trigger a full snapshot; execution and preview hints refresh the matching resource. Reconnects use exponential backoff with jitter, transport heartbeats detect lost connections, and backgrounding cancels the socket. Rejected credentials stop reconnection and direct the user to Account. Unsupported servers display an explicit manual-refresh state. Revoked grants or stopped workspaces dismiss an open preview. Preview creation is never automatically retried: a lost response may have created a grant, so refresh the grant list and revoke the outstanding grant before another issuance. Existing metadata does not contain a recoverable URL.

Feedback uploads use a stable UUID for a retry within the editor. The JPEG is uploaded first and `feedback-<UUID>.json` last as the completion marker. Agents should consume JSON files, then read the referenced JPEG. The report includes the instruction, URL, capture timestamp, container generation, native webview dimensions, display scale, safe-area insets, orientation, OS version, JavaScript layout/visual viewport and scroll position, and bounded errors, warnings, and fetch/XHR failures. Diagnostics reset on navigation; request bodies and headers are not recorded. This captures page JavaScript network failures, not a full native network trace. Uploads follow the API's 1 MiB file limit. Uploaded feedback is ephemeral and disappears when the workspace stops. Page diagnostics and URLs can contain application data; reports remain in the selected workspace.

Text/photo/share messages use the same completion pattern with `message-<UUID>.json`. Each message includes `version`, `createdAt`, `workspaceID`, exact `generation`, `source` (`ios-text`, `ios-photo`, `ios-camera`, `ios-file`, or `ios-share`), `instruction`, `text`, and an optional `attachment` filename relative to `/workspace/inbox`. Camera/file handoffs also include `attachmentName` for the original display name. Upload paths use generated UUID filenames with safe extensions, never the original name. Handoffs save files; they do not launch processes or claim an agent has resumed. Share attachments are JPEGs, at most 2048 pixels on their longest edge and 1 MiB encoded. Shared text is limited to 256 KiB before metadata encoding. The share extension does not accept files, multiple images, or videos. The main app accepts a single file; attaching a ZIP saves it to the inbox and does not extract it or create a workspace.

This version **does not dispatch an agent automatically**. The production activity WebSocket was verified on October 6, 2026. The terminal WebSocket still requires a browser session cookie. There is no agent approval queue, Mainbrella device push registration, or agent-message endpoint. Live updates work in the foreground; background alerts and approvals need a backend push/approval contract. Network tracing, touch replay, voice capture, Live Activities, and Watch support remain future work. Physical camera capture requires verification on an iPhone; simulator checks cover photo resizing/encoding; camera controls are hidden where capture is unavailable.

## Mac Companion alignment

The direction in `../mac.plan.md` is an agent pager across local Macs and cloud machines. This app's native capture and handoff format provides the phone side: a versioned JSON completion marker, the exact destination generation, an instruction, context, and an optional attachment. A future Mac Companion can consume the same payload after its authenticated transport exists. Keep destination identity and transport separate when introducing local machines; a cloud container ID must never stand in for a Mac session or checkpoint identity.

Today the backend has no Companion registration, session/checkpoint, agent dispatch, approval queue, or iOS push-token endpoints. Local Mac destinations, diff/checkpoint review, resume in cloud, approval notifications, and automatic agent continuation need those contracts before they become app controls. The existing activity WebSocket remains the foreground update source; file uploads use user-triggered requests with no polling.

## Development

The main app depends on GoogleSignIn and GoogleSignInSwift through Swift Package Manager. The share extension does not link the Google SDK. `project.yml` is the XcodeGen source, and the generated Xcode project is checked in. Run `xcodegen generate` after editing project configuration.

For physical devices, select the same development team for **Mainbrella** and **MainbrellaShare**. Both targets require the `com.mainbrella.shared` Keychain access group; the containing app retains `com.mainbrella.ios` to migrate keys saved by earlier versions. Signing out or removing the saved API key clears both groups. Credentials stay out of shared files and preferences. See Apple's [Keychain sharing documentation](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) and [extension activation rules](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html). In the system share sheet, use **More** to enable Mainbrella if it isn't initially visible.

```sh
xcodebuild -project Mainbrella.xcodeproj -scheme Mainbrella \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' test
```

Tests cover request identity, one-time preview decoding, ambiguous issuance without automatic retries, upload limits, execution decoding, attachment-before-metadata ordering, authenticated connection state, disconnect cleanup, WebSocket authentication, reconnection, cancellation, capability fallback, generation filtering, scoped reads, invalidations during an in-flight read, burst coalescing, revoked preview dismissal, share input decoding, photo sizing/orientation, bounded file reads, filename safety, legacy message decoding, retry identity, account changes, live share destination invalidation, and the account gate on iPhone and iPad. Tests skip production checks unless explicitly supplied credentials by the smoke script. Account-gate UI tests require a simulator without a saved account. Auth tests cover Google ID-token exchange, email normalization, secure session extraction, session restore/expiry, server logout, offline retention, cancellation, and Keychain failures.

An explicit production smoke check uses the actual Swift client and reads the key from `../backend/.env` without bundling it. It creates **one Lite workspace**, checks photo and file handoff/readback, unchanged retry bytes, retained execution output, and a protected preview, then stops only the generation it created. It attaches the production WebSocket before creating the workspace, verifies lifecycle/execution/preview hints, fetches execution state only after an event, and checks a reconnect snapshot. It never polls. Creation identity is saved in a temporary recovery checkpoint before work starts. If creation or cleanup fails, use that checkpoint to reconcile the same idempotency key/generation before another run.

```sh
swiftc Mainbrella/APIClient.swift Mainbrella/Models.swift scripts/ProductionSmoke.swift \
  -o /tmp/mainbrella-production-smoke
/tmp/mainbrella-production-smoke ../backend/.env
# Add --ui to exercise connection, native share handoff, text handoff, preview, annotation, and screenshot upload.
# Add --ui --handoff-only for the focused native Files picker and handoff/readback check.
# Add --ui --ipad for the iPad simulator. Each invocation creates one temporary workspace.
# Use --ui --simulator-id=<UUID> to select an isolated simulator with no saved account.
```

On October 6, 2026, the photo/file upload, exact-generation metadata, and unchanged-retry checks passed in production. Full preview smoke testing currently encounters HTTP 502 from the protected preview; this remains unresolved. The focused `--ui --handoff-only` check passed: account connection, Files picker presentation/dismissal, native message submission, and production readback. Its temporary workspace was stopped and its saved test key removed.

Production UI checks require an initially disconnected simulator and remove the saved test key afterward. They create an execution after the app connects and verify that its row and open output update automatically, share retained errors through the actual system extension, then exercise the native Files picker, text handoff, preview, annotation, and screenshot upload. The script reads back the share message from production to verify its content and generation. The remaining UI tests run without production credentials. Neither the production test script nor its credentials are part of the app target.

If an interrupted UI run leaves a test key behind, remove it from **Account** on that dedicated test simulator. The optional `testRemoveSmokeAccount` UI test does the same when explicitly enabled with `TEST_RUNNER_MAINBRELLA_REMOVE_SMOKE_ACCOUNT=1`; it is skipped during ordinary test runs.

The existing `1024.png` is used for the app icon; the original file is preserved.
