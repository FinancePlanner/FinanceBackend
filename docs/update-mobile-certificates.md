# Rotating iOS signing certificates

Both mobile applications sign against the same Apple Developer team,
`84X9WYBF36`:

| Application | Repository | Match storage |
|---|---|---|
| Norviq iOS | `FinancePlanner/norviq-ios` | `FinancePlanner/norviq-certificates` (branch `master`) |
| LuminaVault | `LuminaVault/LuminaVaultClient` | `LuminaVault/LuminaVaultIOSSecrets` (branch `master`) |

Apple caps a team at three Distribution certificates. Because the two
applications share a team, they share that cap, and the cap is what makes
rotation non-trivial: when it is reached, Fastlane Match cannot create a
certificate and fails with

```
Could not create another Distribution certificate, reached the maximum
number of available Distribution certificates.
```

**Always rotate by letting Match generate the certificate.** A
Match-generated private key is written in a format the runner can import. A
key exported by hand from Keychain Access, or converted with `openssl`,
usually is not — see [Why manual export is a last
resort](#why-manual-export-is-a-last-resort). Freeing a slot first is what
makes generation possible.

## State as of 2026-08-28

| Certificate | Expires | In use by |
|---|---|---|
| `4AQ4Q8XM7Z` | 2027-07-16 | Norviq iOS; private key exists only in `norviq-certificates` |
| `SDXB77U52T` | 2027-06-04 | LuminaVault |
| `LJ63C7B8WR` | 2027-06-04 | nothing — leftover from an abandoned bootstrap |
| `MQ57KWXF8N` | 2027-02-12 | Development certificate; does not count toward the Distribution cap |

`LJ63C7B8WR` is the slot to reclaim at the next rotation. Revoking it ahead of
time leaves a free slot standing by, which reduces rotation to steps 3 to 5.

## 1. Inventory the certificates

Run from either iOS repository, with an App Store Connect API key available:

```sh
export ASC_KEY_ID=<key id>
export ASC_ISSUER_ID=<issuer id>
export ASC_P8=~/Downloads/AuthKey_$ASC_KEY_ID.p8

bundle exec ruby -e '
require "spaceship"; require "openssl"; require "base64"
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: ENV["ASC_KEY_ID"], issuer_id: ENV["ASC_ISSUER_ID"],
  filepath: File.expand_path(ENV["ASC_P8"]))
Spaceship::ConnectAPI::Certificate.all.each { |c|
  der = Base64.decode64(c.certificate_content)
  fp = OpenSSL::Digest::SHA1.new(der).to_s.upcase.scan(/../).join(":")
  puts "#{c.id}  #{c.certificate_type}  exp=#{c.expiration_date.to_s[0,10]}  #{fp}" }'
```

The fingerprint column matches `security find-identity -v -p codesigning`
locally, which is the only reliable way to tell two certificates apart: they
share the common name `Apple Distribution: Fernando Correia (84X9WYBF36)`.

## 2. Establish which certificates are actually in use

A certificate is in use only if it is committed to a Match repository.
Presence in the portal, or in your local keychain, proves nothing.

```sh
gh api /repos/LuminaVault/LuminaVaultIOSSecrets/contents/certs/distribution --jq '.[].name'
gh api /repos/FinancePlanner/norviq-certificates/contents/certs/distribution --jq '.[].name'
```

Anything the portal lists that neither repository holds is dead weight and is
the correct thing to revoke.

## 3. Revoke one certificate to free a slot

Revoke through the Developer portal: Certificates, Identifiers & Profiles,
select the certificate, Revoke. Revocation cannot be undone.

Before revoking, confirm the certificate is not the one the *other*
application depends on. Revoking `4AQ4Q8XM7Z` breaks Norviq's TestFlight
pipeline, and its private key exists nowhere except inside
`norviq-certificates`, so it cannot be reconstructed from a local keychain.

Never run `fastlane match nuke distribution`. It revokes every Distribution
certificate and provisioning profile belonging to the team, across both
applications. There is no per-application scoping.

## 4. Remove the old certificate from Match storage

This step is easy to skip and rotation silently does nothing without it. Match
reuses any valid certificate it finds in the repository, so it will not create
a replacement while the old pair is still committed:

```sh
git clone git@github.com:LuminaVault/LuminaVaultIOSSecrets.git /tmp/lvsecrets
cd /tmp/lvsecrets
git checkout master
git rm certs/distribution/<OLD_CERT_ID>.cer certs/distribution/<OLD_CERT_ID>.p12
git commit -m "chore: drop expiring distribution certificate so match regenerates"
git push
```

Match's default branch is `master`, not `main`. Both storage repositories keep
their contents there. A `gh api .../contents/...` call without an explicit ref
reads the repository's default branch and will return 404 against
`LuminaVaultIOSSecrets`, whose default is `main` and holds only a README.

## 5. Let Match generate the certificate

```sh
cd ~/Work/production/apps/lumina/LuminaVaultClient

export MATCH_PASSWORD=<storage passphrase>
export MATCH_GIT_URL='git@github.com:LuminaVault/LuminaVaultIOSSecrets.git'
export APP_STORE_CONNECT_API_KEY_ID=$ASC_KEY_ID
export APP_STORE_CONNECT_API_KEY_ISSUER_ID=$ASC_ISSUER_ID
export APP_STORE_CONNECT_API_KEY_KEY=$(base64 -i $ASC_P8 | tr -d '\n')

bundle exec fastlane sync_signing
```

With a free slot and no certificate in storage, Match creates the certificate
and the private key, then regenerates every provisioning profile against it.

Use the SSH remote locally, where your own key authenticates the push. CI uses
the HTTPS remote with `MATCH_GIT_BASIC_AUTHORIZATION`; see
[ios-deployment.md](ios-deployment.md).

The Norviq equivalent is `bundle exec fastlane beta`, whose lane owns signing
bootstrap, or the `seed-signing` workflow. Note that seeding on a runner leaves
the private key only in Match storage and never on your machine, which is how
`4AQ4Q8XM7Z` came to exist without a local copy.

## 6. Verify, then exercise the pipeline

```sh
gh api "/repos/LuminaVault/LuminaVaultIOSSecrets/git/trees/master?recursive=1" \
  --jq '.tree[] | select(.type=="blob") | .path'
```

Expect a new `<CERTID>.cer` and `<CERTID>.p12` under `certs/distribution/`, and
one profile per signable bundle identifier under `profiles/appstore/`. For
LuminaVault that is three profiles; for Norviq, two.

Then dispatch the workflow rather than waiting for a merge, so a bad rotation
surfaces immediately instead of on someone else's push:

```sh
gh workflow run testflight.yml --repo LuminaVault/LuminaVaultClient \
  -f changelog="post-rotation check"
```

Confirm the build arrived, rather than trusting a green job:

```sh
bundle exec ruby -e '
require "spaceship"
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: ENV["ASC_KEY_ID"], issuer_id: ENV["ASC_ISSUER_ID"],
  filepath: File.expand_path(ENV["ASC_P8"]))
app = Spaceship::ConnectAPI::App.find("com.lumina.fernando.beta")
app.get_builds.first(3).each { |b|
  puts "build #{b.version}  #{b.processing_state}  #{b.uploaded_date}" }'
```

## Why manual export is a last resort

Match imports the private key with an empty passphrase, hardcoded:

```ruby
# fastlane_core/lib/fastlane_core/keychain_importer.rb
def self.import_file(path, keychain_path, keychain_password: nil,
                     certificate_password: "", ...)
  password_part = " -P #{certificate_password.shellescape}"
```

`Match::Utils.import` never overrides `certificate_password`, so the stored
`.p12` must open with `-P ''`. Two consequences:

- A Keychain Access export protected by a password can never work in CI, no
  matter which flags the workflow passes.
- The file must also be written by Apple's exporter. OpenSSL 3 defaults to
  `MAC: sha256`, which `SecKeychainItemImport` rejects with `MAC verification
  failed during PKCS12 import (wrong password?)` — a misleading message for
  what is a format problem, not a password problem. Re-exporting with
  `-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES` is also
  rejected.

If a manual export is genuinely unavoidable, round-trip through Apple's own
tools. Import the password-protected `.p12` into a temporary keychain, then
export it back out with an empty passphrase:

```sh
KC=/tmp/xfer.keychain-db
security create-keychain -p x "$KC"
security unlock-keychain -p x "$KC"
security import ~/Downloads/dist.p12 -k "$KC" -P '<export password>' -A \
  -T /usr/bin/codesign -T /usr/bin/security
security export -k "$KC" -t identities -f pkcs12 -P '' -o ~/Downloads/dist-blank.p12
security delete-keychain "$KC"
```

The result carries `MAC: sha1, Iteration 1`. Verify it before committing
anything, using the same call CI makes:

```sh
KC=/tmp/probe.keychain-db
security create-keychain -p p "$KC" && security unlock-keychain -p p "$KC"
security import ~/Downloads/dist-blank.p12 -k "$KC" -P '' -T /usr/bin/codesign
security find-identity -v -p codesigning "$KC"   # must report 1 valid identity
security delete-keychain "$KC"
```

`fastlane match import` cannot be scripted: `commands_generator.rb` calls
`import_cert(params)` with no path arguments, so the paths come only from
`UI.input` and the command requires a TTY. `Match::Importer#import_cert`
accepts them as keyword arguments, so a short Ruby script can do the same work
non-interactively. Require `fastlane` before `match`, or
`Match::Options.default_platform` raises `uninitialized constant
Fastlane::Actions`. Pass `profile_path: ""` rather than `nil` to skip the
optional profile prompt.

Delete every local copy of the `.p12` afterwards. The authoritative copy is the
one in Match storage.

## Related failure modes

These are not certificate problems, but they present as signing failures and
cost time when misread.

**Automatic signing.** If a target's build configuration is
`CODE_SIGN_STYLE = Automatic` with no `CODE_SIGN_IDENTITY` and no
`PROVISIONING_PROFILE_SPECIFIER`, xcodebuild ignores the App Store profiles
Match installed and tries to generate an iOS App Development profile of its
own, which needs `-allowProvisioningUpdates` and credentials a runner does not
have. Every target reports "No profiles for X were found", so it looks as
though Match never ran. The profile type named in the error is the tell:
Development, not App Store. Both Fastfiles pin manual signing per target and
per configuration before archiving — `prepare_signing` in each.

**Missing target identifiers.** Every signable target needs its own profile,
because each has its own bundle identifier. LuminaVault has three:
`LuminaVaultClient`, `LuminaVaultShareExtension`, and
`LuminaVaultWidgetsExtension`. If one is absent from the Fastfile's identifier
list, Match reports success for the others and the archive fails only on the
one it was never told about.

**An unset GitHub secret is an empty string, not nil.** A workflow that maps a
missing secret into the environment produces `""`, which is truthy in Ruby, so
guards of the form `if ENV["APP_STORE_CONNECT_API_KEY_KEY"]` pass and fastlane
attempts to base64-decode nothing as a `.p8`. The symptom is
`invalid curve name (OpenSSL::PKey::ECError)` from
`spaceship/connect_api/token.rb`. Check `gh secret list` before debugging the
key itself.
