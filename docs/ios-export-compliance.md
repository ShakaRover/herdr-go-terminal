# iOS encryption export compliance audit

Technical audit date: August 28, 2026.

This document records what the HerdrGo iOS binary contains and maps those facts
to Apple's export-compliance questions. It is not a legal opinion. The final
App Store Connect declaration remains the developer's attestation.

## Shipped artifact

- Library: `app/ios/Frameworks/iphoneos/libeasytier_ios.a`
- SHA-256:
  `7845280cf9470f6761e260f2cec1fd8a8ba5bd6ba5da02574da52b5f27b61933`
- Embedded EasyTier version string: `2.6.4`
- Build entry point: `app/tool/build_ios_easytier.sh`
- EasyTier crate: `easytier-contrib/easytier-ios`

The iOS crate disables the default features of `easytier-ffi`, but that crate
depends on `easytier` with its default features. The resulting static library
therefore contains EasyTier's Rust cryptographic implementations and optional
protocol code in addition to the paths HerdrGo uses at runtime.

## Cryptography in the binary

HerdrGo's generated EasyTier configuration does not disable encryption or
select a different algorithm. EasyTier therefore uses its encrypted default:

- Data-plane encryption: AES-128-GCM through the `ring` backend.
- Peer handshake: `Noise_XX_25519_ChaChaPoly_SHA256`.
- Relay handshake: `Noise_IK_25519_ChaChaPoly_SHA256`.
- Key agreement and derivation: X25519, SHA-256, and HKDF as defined by the
  published Noise framework.

The linked binary also contains code for AES-256-GCM, ChaCha20-Poly1305,
Rustls/TLS, QUIC, and BoringTun/WireGuard because those features are present in
the EasyTier dependency graph. HerdrGo configures no TUN device, VPN portal, or
WireGuard listener, but export declarations generally consider encryption the
app contains, not only the path exercised in one configuration.

The algorithms are public, widely documented standards or published protocol
specifications:

- AES-GCM: NIST SP 800-38D
- X25519: RFC 7748
- ChaCha20-Poly1305: RFC 8439
- HKDF: RFC 5869
- SHA-256: FIPS 180-4
- Noise Protocol Framework, Revision 34

No HerdrGo code introduces a secret, proprietary, or unpublished cipher.
EasyTier combines the published primitives through a published Noise handshake
and its open-source data-plane protocol.

## Recommended App Store Connect answers

Use the wording shown in the current App Store Connect questionnaire rather
than relying on question order, which Apple can change.

1. **Does the app use, access, contain, implement, or incorporate encryption?**
   **Yes.**
2. **Is encryption limited to cryptography provided by Apple's operating
   system?** **No.** The app links Rust implementations through EasyTier.
3. **Does the app implement standard encryption algorithms in addition to
   Apple's operating-system encryption?** **Yes.**
4. **Does the app contain proprietary or non-standard, unpublished
   cryptography?** **No**, based on the source and binary audit above.
5. **Does the app contain third-party cryptography?** **Yes.** EasyTier,
   `ring`, `snow`, Rustls, and related crates are linked into the app.
6. **Will the app be distributed in France?** Answer from the selected
   storefronts. Apple currently says an app using an industry-standard
   algorithm outside the Apple operating system must upload a French
   encryption declaration when distributed in France.

For the lowest-friction first submission, omit France until the French
declaration is ready. This is independent of the separate recommendation to
omit mainland China until its regional documentation is confirmed.

## Info.plist decision

Do not add `ITSAppUsesNonExemptEncryption = NO` before Apple evaluates the
first questionnaire. That value would be unsafe if Apple does not treat this
distribution as exempt from documentation.

After the questionnaire:

- If Apple determines no documentation is required, set
  `ITSAppUsesNonExemptEncryption` to `NO` for later builds.
- If Apple requires documentation, leave the declaration as non-exempt, upload
  the requested files, and add Apple's approved
  `ITSEncryptionExportComplianceCode` to later builds.

## U.S. mass-market assessment

HerdrGo is a free, publicly available, complete consumer application. It is not
sold as an encryption component, SDK, cryptanalytic tool, or custom network
infrastructure product. Those facts support a likely mass-market software
classification rather than treatment as proprietary cryptography.

The U.S. Bureau of Industry and Security states that some mass-market software
can be self-classified, while particular components, executable software, and
other categories can have reporting or classification requirements. Because
the binary embeds a broad EasyTier feature set, retain this audit and confirm
the applicable ECCN/reporting path before worldwide distribution. A BIS CCATS
request can be used when an official classification is preferred.

## Primary references

- Apple, [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- Apple, [Encryption documentation by algorithm](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)
- Apple, [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
- BIS, [Mass market encryption](https://www.bis.gov/learn-support/encryption-controls/mass-market)
- BIS, [Encryption items not subject to the EAR](https://www.bis.gov/learn-support/encryption-controls/encryption-items-not-subject-to-ear)
- Noise Protocol Framework, [Revision 34 specification](https://noiseprotocol.org/noise.html)
