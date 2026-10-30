# Quill

SwiftUI and SwiftData app for iPhone and iPad: iOS 18+, Swift 6 with MainActor default
isolation. See `README.md` for the layout.

## Commands

```sh
xcodegen generate                                # after changing project.yml or adding files
scripts/test-app.sh                              # app tests, iPhone simulator
SIM="iPad Pro 13-inch (M5)" scripts/test-app.sh  # app tests, iPad simulator
scripts/test-app.sh -only-testing:QuillUITests   # one suite
scripts/test-ghostkit.sh                         # API client, on the Mac
```

The test scripts create a fresh Ghost on `docker-server` and delete it afterwards. See
`TESTING.md`.

## Testing

- Tests run locally only. GitHub Actions just builds and publishes, so don't add CI there.
- End-to-end only, against a real Ghost. Don't add unit tests or mocks.
- Run both iPhone and iPad before committing UI changes; layout code differs between them.
- Check the screenshots too, because a passing test can't see a visual regression:
  `xcrun xcresulttool export attachments --path build/results.xcresult --output-path <dir>`
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
- **Writing surface:** it uses the system monospace font. The iA fonts' terms forbid bundling
  them in a text editor.

## Product rules

- There's no draft step. Writing saves itself, and going back from a new entry keeps it in
  Drafts. Never add a Save Draft action.
- Going back from an edit of a published post cancels the edit.
- Sent and the Outbox stay out of the way: the Outbox only appears on an error or a slow send.
- Titles are optional. A site must exist before any writing is possible.

## Secrets

Never commit keys. `*.p8` and `.dev/` are gitignored, and Ghost keys live in the Keychain.
Releases are covered in `RELEASING.md`.
