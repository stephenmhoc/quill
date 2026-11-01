# Releasing

## TestFlight

`.github/workflows/release.yml` archives Quill, signs it with a long-lived distribution
certificate, uploads it to App Store Connect and waits for Apple to finish processing it.

Never revoke that certificate while builds still need it. Doing so before processing fails with
`ITMS-90721`, and doing so before TestFlight review fails with `ITMS-90035`.

### One-time setup

1. In App Store Connect, create an app with the bundle ID `com.merimerimeri.Quill`. The API
   can't create app records, so this has to be done by hand. The name must be unique across the
   App Store, so the listing can't be plain "Quill". That only shows in App Store Connect and
   TestFlight; the home screen name comes from the build.
2. On that App ID, under Certificates, Identifiers & Profiles → Identifiers, enable **Data
   Protection** with Complete Protection. Without it, signing fails on the app's entitlement.
3. Create an App Store Connect API key: Users and Access → Integrations → App Store Connect API
   → Team Keys. Give it the **Admin** role, because the workflow creates distribution
   certificates. Then add these repository secrets:

   | Secret | Where it comes from |
   |---|---|
   | `ASC_KEY_ID` | The **Key ID** column in the key's row |
   | `ASC_ISSUER_ID` | **Issuer ID**, at the top of the same page |
   | `ASC_API_KEY_P8_BASE64` | The `AuthKey_<Key ID>.p8` file, Base64 encoded |

   The `.p8` can be downloaded only once, so keep a copy somewhere safe, such as a password
   manager. If it's lost, revoke the key and create another. GitHub can't show secret values
   afterwards, so they can't be copied from another repository.

   ```sh
   gh secret set ASC_KEY_ID -R stephenmhoc/quill
   gh secret set ASC_ISSUER_ID -R stephenmhoc/quill
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_API_KEY_P8_BASE64 -R stephenmhoc/quill
   ```

4. Create the distribution certificate, which also sets its three `APPLE_DISTRIBUTION_CERT_*`
   secrets, with the Issuer ID from step 3 and your `.p8`. Run this again before it expires, about
   a year on. The next release makes a matching profile by itself.

   ```sh
   ASC_ISSUER_ID=<Issuer ID> ASC_KEY_ID=<Key ID> ASC_API_KEY_PATH=AuthKey_<Key ID>.p8 \
     ruby Tools/app_store_connect_signing.rb create-distribution-cert
   ```

### Shipping a build

Push a version tag, or run the workflow by hand with a version:

```sh
git tag v0.2.0 && git push origin v0.2.0
gh workflow run release.yml -R stephenmhoc/quill -f version=0.2.0
```

The tag sets the version and the run number sets the build number.

Quill ships through TestFlight only, never the App Store, and TestFlight builds expire after 90
days. `refresh-testflight.yml` checks weekly and, if the last iOS build is 30 days old, releases the
next patch version from `main`. If the distribution certificate has expired, that build fails: run
`create-distribution-cert` above again.

After upload, every release goes to all external TestFlight groups and to Beta App Review, with its
`release_notes` as the test notes, or a generic line if there are none. Monthly rebuilds go too, so
public testers' builds don't expire. A failed submission leaves the release in place: fix the cause,
then retry with `gh workflow run send-to-external-testers.yml -f build_number=<n> -f test_notes=<notes>`.

GitHub only builds and publishes. All testing is local, so run the suites from `TESTING.md` on
iPhone, iPad and Mac before tagging.

## Mac

The Mac app ships outside the App Store: a notarized DMG on GitHub, then updates through Sparkle.

Push a `v<version>-mac` tag, for example `v0.1.2-mac`. `release-mac.yml` builds and notarizes the app, publishes the DMG and the update ZIP, and finally replaces the feed on the `appcast` release. iOS tags are unaffected. To write the update dialog's notes, run the workflow by hand with `release_notes` instead.

The newest DMG is always at `https://github.com/stephenmhoc/quill/releases/download/mac-latest/Quill.dmg`. Link to that, not a version. `mac-latest` is a standing release that each Mac release overwrites, like `appcast`, because GitHub's own latest link follows the iOS releases.

The workflow needs the `ASC_*` secrets above, plus `DEVELOPER_ID_CERT_BASE64` (the Developer ID Application certificate and its private key, exported from Keychain Access as a `.p12` and Base64 encoded), `DEVELOPER_ID_CERT_PASSWORD` (that export's password) and `SPARKLE_PRIVATE_KEY`.

The update key's public half is `SUPublicEDKey` in `project.yml`. The private half is the `SPARKLE_PRIVATE_KEY` secret, and in the login Keychain under the account `quill`. Losing it means installed copies can't update.

Local builds in every configuration are `com.merimerimeri.Quill.dev` with the Dev icon. The workflow alone sets the real identity, through `QUILL_BUNDLE_ID` and `QUILL_APP_ICON`, and fails if the archive comes out as anything else.

The Developer ID profile is created once, as "Quill Developer ID", and reused. Replacing the Developer ID certificate means deleting that profile so the next release makes a new one.
