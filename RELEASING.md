# Releasing to TestFlight

`.github/workflows/release.yml` archives Quill, signs it with a temporary certificate and
profile, uploads it to App Store Connect, waits for Apple to finish processing it, then revokes
the temporary signing assets. Revoking any earlier fails processing with `ITMS-90721`.

## One-time setup

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

## Shipping a build

Push a version tag, or run the workflow by hand with a version:

```sh
git tag v0.2.0 && git push origin v0.2.0
gh workflow run release.yml -R stephenmhoc/quill -f version=0.2.0
```

The tag sets the version and the run number sets the build number.

GitHub only builds and publishes. All testing is local, so run the suites from `TESTING.md` on
iPhone and iPad before tagging.

## Mac

The Mac app ships outside the App Store: a notarized DMG on GitHub, then updates through Sparkle.

Push a `v<version>-mac` tag, for example `v0.1.2-mac`. `release-mac.yml` builds and notarizes the app, publishes the DMG and the update ZIP, and finally replaces the feed on the `appcast` release. iOS tags are unaffected. To write the update dialog's notes, run the workflow by hand with `release_notes` instead.

The workflow needs the `ASC_*` secrets above, plus `DEVELOPER_ID_CERT_BASE64` (the Developer ID Application certificate and its private key, exported from Keychain Access as a `.p12` and Base64 encoded), `DEVELOPER_ID_CERT_PASSWORD` (that export's password) and `SPARKLE_PRIVATE_KEY`.

The update key's public half is `SUPublicEDKey` in `project.yml`. The private half is the `SPARKLE_PRIVATE_KEY` secret, and in the login Keychain under the account `quill`. Losing it means installed copies can't update.

The Developer ID profile is created once, as "Quill Developer ID", and reused. Replacing the Developer ID certificate means deleting that profile so the next release makes a new one.
