# Quill

SwiftUI and SwiftData app for iPhone, iPad and Mac: iOS 18+ and macOS 26+, Swift 6 with MainActor
default isolation. See `README.md` for the layout.

## Commands

```sh
xcodegen generate                                # after changing project.yml or adding files
scripts/test-all.sh                              # everything, before a commit: about 5 minutes
scripts/test-app.sh                              # app tests, iPhone simulator
SIM="iPad Pro 13-inch (M5)" scripts/test-app.sh  # app tests, iPad simulator
scripts/test-app.sh -only-testing:QuillUITests   # one suite
scripts/test-ghostkit.sh                         # API client, on the Mac
scripts/test-mac.sh                              # Mac app, on its own .dev identity
```

The test scripts create a fresh Ghost on `docker-server` and delete it afterwards. See
`TESTING.md`.

## Testing

- Tests run locally only. GitHub Actions just builds and publishes, so don't add CI there.
- End-to-end only, against a real Ghost. Don't add unit tests or mocks.
- Keep them as light as they can be: a few journeys through what would really hurt if it broke.
  Don't add a check for a control, a layout or a setting. Prove a fix once and don't keep the test.
- Micro.blog tests use the user's real blog, which cross-posts. They must only create drafts,
  delete what they make, and never tap send in the UI. See `TESTING.md`.
- Run `scripts/test-all.sh` before committing UI changes; layout code differs between iPhone
  and iPad. It builds once, runs the live tests once, then the UI tests on both at the same time.
  While iterating, use `scripts/test-app.sh` with `-only-testing:` for the test at hand.
- Builds aren't the slow part (a clean build is about 11 seconds); the UI tests are.
- On iPad, XCTest sometimes waits a minute per step for an animation signal that never comes,
  with the app idle at 0% CPU. It's a test tool problem. Swizzling the wait crashes the runner.
  Once it starts it can repeat every run: `xcrun simctl shutdown` the simulator and rerun, twice
  if the first run fails to unlock, because Face ID enrolment races a fresh boot. Don't shut it down
  between those runs: wait a minute and rerun.
- Check the screenshots too, because a passing test can't see a visual regression:
  `xcrun xcresulttool export attachments --path build/results-iphone.xcresult --output-path <dir>`
  (`results-ipad`, `results-live`; `test-app.sh` writes `build/results.xcresult`).
- Look for `Modifying state during view update` and compiler warnings in the logs. Keep the
  build free of warnings.

## Architecture rules

- **New kinds of site:** add a `SiteKind` and a `SiteBackend`. `Publisher.backend(for:)` and
  `siteForm(kind:site:isCentered:onDone:)` are the only places that switch on the kind, so
  don't branch on `local` elsewhere.
- **Layout decisions:** use the `usesColumns` environment value, never `horizontalSizeClass`
  inside a column. iPad's sidebar column reports compact.
- **iPhone lists:** use a plain `List`. `List(selection:)` with `NavigationLink` pushes twice.
- **Deleted models:** a SwiftData model can be deleted during any `await`, or while a view still
  holds it. Check `modelContext != nil && !isDeleted` after awaiting and before reading in a
  view. Call `Navigation.leaveSite(_:)` before deleting a site's data.
- **UIKit:** the editor is a `UITextView` because `TextEditor` can't scroll a title with the
  text. Everything else stays SwiftUI unless SwiftUI visibly limits the interface.
- **Mac:** `QuillMac` is a native target, not Catalyst, listed file by file in `project.yml`. It
  shares models, services, the vault and site forms, and has its own window, editor (`NSTextView`)
  and menus. Don't reuse iOS layouts there. Put small differences in `PlatformStyle.swift`.
- **Writing surface:** it uses the system monospace font. The iA fonts' terms forbid bundling
  them in a text editor.

## Product rules

- There's no draft step. Writing saves itself, and going back from a new entry keeps it in
  Drafts. Never add a Save Draft action.
- Going back from an edit of a published post cancels the edit on iOS. A Mac has no back button, so
  real changes stay in Drafts until they're published or discarded.
- Focus mode hides everything but the page. On a Mac it's ⇧⌘F, not ⌘\, which 1Password takes.
- Sent and the Outbox stay out of the way: the Outbox only appears on an error or a slow send.
- Titles are optional. A site must exist before any writing is possible.

## Releases

Each version's release notes say what changed and, where possible, why. See `RELEASING.md` for how
they're passed to the workflow.

## Secrets

Never commit keys. `*.p8` and `.dev/` are gitignored, and Ghost keys live in the Keychain.
Releases are covered in `RELEASING.md`.
