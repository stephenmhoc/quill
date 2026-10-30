# Releasing to TestFlight

`.github/workflows/release.yml` archives Quill, signs it with a temporary certificate and
profile, uploads it to App Store Connect and revokes the temporary signing assets again.

## One-time setup

1. In App Store Connect, create an app with the bundle ID `com.merimerimeri.Quill`. The API
   can't create app records, so this has to be done by hand.
2. Add the same three secrets Tabata Ticker uses. GitHub won't reveal their values, so they
   come from wherever the `.p8` file is kept:

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
