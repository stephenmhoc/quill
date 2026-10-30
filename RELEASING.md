# Releasing to TestFlight

`.github/workflows/release.yml` archives Quill, signs it with a temporary certificate and
profile, uploads it to App Store Connect and revokes the temporary signing assets again.

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

The tag sets the version and the run number sets the build number. Run the e2e suites first
(see `TESTING.md`): they need the homelab test Ghost, so CI only runs the GhostKit tests.
