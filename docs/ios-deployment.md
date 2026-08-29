# iOS deployment with Fastlane

The Norviq iOS application is built, signed, tested, and uploaded by Fastlane in
GitHub Actions. Xcode Organizer is not part of the normal release process.

The canonical implementation lives in the `FinancePlanner/norviq-ios`
repository:

- `.github/workflows/release.yml` defines TestFlight and App Store jobs.
- `fastlane/Fastfile` defines the `beta`, `release`, and `hotfix` lanes.
- `fastlane/Matchfile` defines encrypted signing storage.
- `fastlane/Appfile` defines the bundle identifier and Apple team.

## What is automated

Fastlane performs the following work:

- selects the supported Xcode and iOS SDK;
- authenticates with the App Store Connect API;
- installs or renews the distribution certificate and provisioning profile;
- selects a build number greater than every previous App Store Connect build;
- archives and signs the application;
- uploads the build to TestFlight or App Store Connect;
- waits for TestFlight processing;
- submits production builds for App Review;
- uploads dSYMs to Sentry when Sentry credentials are configured.

## One-time setup

### GitHub Actions secrets

Configure these repository secrets in `FinancePlanner/norviq-ios`:

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_P8`, containing the base64-encoded App Store Connect `.p8` key
- `MATCH_PASSWORD`
- `MATCH_GIT_BASIC_AUTHORIZATION`
- `SECRETS_XCCONFIG`
- `SENTRY_ORG`, `SENTRY_PROJECT`, and `SENTRY_AUTH_TOKEN` when dSYM upload is enabled

Never commit these values or print them in workflow logs.

### Signing storage

Fastlane Match stores encrypted certificates and provisioning profiles in the
private `FinancePlanner/norviq-certificates` repository. The `beta` lane may
bootstrap or renew signing assets. Production release lanes consume the stored
assets in read-only mode when running in CI.

Replacing an expiring distribution certificate is documented separately in
[update-mobile-certificates.md](update-mobile-certificates.md). Norviq shares
Apple team `84X9WYBF36` with LuminaVault, and therefore shares Apple's
three-certificate cap, so rotation is not independent between the two.

### Production approval gate

Before the first production release, create a GitHub environment named exactly
`app-store`:

1. Open `FinancePlanner/norviq-ios` in GitHub.
2. Go to **Settings → Environments**.
3. Create the `app-store` environment.
4. Add the release owner as a required reviewer.
5. Restrict deployment branches to `main`.

The workflow references this environment. Configure its protection rules before
the first manual production run; an environment without protection does not
provide a release approval gate.

## TestFlight workflow

Every push to `main`, including a merged pull request, starts the `beta` lane.
No Xcode or App Store Connect interaction is required.

1. Complete the feature on a branch.
2. Merge the pull request into `main`.
3. Open the [Release workflow](https://github.com/FinancePlanner/norviq-ios/actions/workflows/release.yml).
4. Wait for the `TestFlight (beta)` job to pass.
5. Confirm the new build is `VALID` in TestFlight if release verification is required.

The current lane uploads builds for internal testing only because
`distribute_external` is disabled. External tester groups require an explicit
Fastlane group and external-distribution configuration.

## Production App Store release

The `release` lane creates a new signed build, uploads it, submits it for App
Review, enables automatic release, and enables phased rollout.

Before running it, commit the target marketing version to the Xcode project and
merge that change into `main`. Keeping the version in source control prevents a
later TestFlight build from returning to a closed release train.

### GitHub interface

1. Open the [Release workflow](https://github.com/FinancePlanner/norviq-ios/actions/workflows/release.yml).
2. Select **Run workflow**.
3. Select the `main` branch.
4. Select the `release` lane.
5. Enter the marketing version, or leave it empty to use the version committed to `main`.
6. Start the workflow.
7. Approve the `app-store` environment deployment.
8. Monitor the job until Fastlane confirms submission.

### GitHub CLI

Replace `1.0.2` with the version being released:

```bash
gh workflow run release.yml \
  --repo FinancePlanner/norviq-ios \
  --ref main \
  -f lane=release \
  -f version=1.0.2
```

The production lane skips screenshot upload and retains the screenshots already
stored in App Store Connect. Add version-controlled `fastlane/metadata` files to
the iOS repository if release notes and other store metadata should also be
managed by Fastlane.

## Hotfix release

The `hotfix` lane follows the production flow but disables phased rollout. Use a
new marketing version and merge that version into `main` before dispatching the
workflow.

```bash
gh workflow run release.yml \
  --repo FinancePlanner/norviq-ios \
  --ref main \
  -f lane=hotfix \
  -f version=1.0.3
```

Approve the `app-store` environment deployment when GitHub requests it.

## Running Fastlane locally

GitHub Actions is the recommended release interface because its secrets,
toolchain, and signing keychain are reproducible. For local diagnostics, run
Fastlane from the iOS repository:

```bash
bundle install
bundle exec fastlane test
bundle exec fastlane ui_test
```

The release lanes can also run locally:

```bash
bundle exec fastlane beta
bundle exec fastlane release version:1.0.2
bundle exec fastlane hotfix version:1.0.3
```

Local release commands require the same App Store Connect, Match, application
configuration, and optional Sentry environment variables used by GitHub
Actions. Do not copy secrets into shell history; load them from a secure local
secret store.

## Version and build-number rules

- Commit marketing-version changes, such as `1.0.2`, to `main`.
- Do not manually increment `CFBundleVersion` for CI releases.
- Fastlane queries all App Store Connect build trains and uses the highest
  numeric build plus one.
- Do not reuse a closed marketing-version train.
- A production workflow creates and uploads a new build; it does not promote an
  already uploaded TestFlight binary.

## Remaining Apple-managed steps

Fastlane cannot bypass Apple review or account requirements. App Store Connect
may still require an account holder to complete agreements, export-compliance
questions, privacy declarations, pricing, or review responses. Handle these only
when Apple blocks the automated submission.

## Troubleshooting

### App Store Connect returns HTTP 401

Confirm that `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` belong to the same
App Store Connect API key. The key must have sufficient App Store Connect and
certificate-management access.

### Bundle version was already used

Do not hardcode the next build number. Confirm the current Fastfile still scans
all build trains and selects the maximum build number plus one.

### Apple rejects the SDK version

Check the Xcode version in the release workflow and the SDK version currently
required by App Store Connect. CI and Release should use the same supported
Xcode toolchain.

### Pre-release train is closed

Increase the marketing version, commit the project change, merge it to `main`,
and rerun the release.
