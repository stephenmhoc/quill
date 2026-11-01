# Quill

A minimal app for iPhone, iPad and Mac for writing and publishing to your own sites. Write in
Markdown and tap Publish, with no draft step and no extra screens.

- **Sites:** connect Ghost sites and Micro.blog blogs, or keep a Local site that lives only on
  this device.
- **Writing:** a quiet editor with Markdown styled as you type. Titles are optional, and
  unsent writing saves itself to Drafts on this device.
- **Past posts:** browse, edit and delete what's already published.
- **Outbox:** anything that can't send waits and retries by itself.
- **Privacy:** Face ID or Touch ID locks the app, and site keys stay in the Keychain.
- **Focus mode:** hides everything but the page, on every platform.
- **iPad and Mac:** three columns. The Mac app is native, not Catalyst, with its own menus and
  shortcuts, and it updates itself through Sparkle.

## Getting started

You need Xcode 27.1 or later and XcodeGen (`brew install xcodegen`).

```sh
xcodegen generate
open Quill.xcodeproj
```

`project.yml` is the source of truth for the Xcode project. Regenerate after changing it, or
after adding or removing files.

To connect a Ghost site, copy the Staff access token from your profile in Ghost Admin and paste
it into Quill with the site address. For Micro.blog, paste an app token from Account → App tokens.

## Layout

| Path | What's there |
|---|---|
| `Quill/` | The iPhone and iPad app: models, services and views, many shared with the Mac |
| `QuillMac/` | The Mac app's own window, editor and menus |
| `Packages/GhostKit/` | Ghost and Micropub API clients, and Markdown/HTML conversion |
| `QuillTests/`, `QuillUITests/` | End-to-end tests against a real Ghost |
| `QuillMacUITests/` | One end-to-end journey on the Mac |
| `testenv/`, `scripts/` | The test Ghost and the scripts that run it |
| `Tools/` | App Store Connect signing for releases |
| `design/` | App icon sources |

## More

- [TESTING.md](TESTING.md): running the tests and setting up the test Ghost
- [RELEASING.md](RELEASING.md): shipping to TestFlight and releasing the Mac app
