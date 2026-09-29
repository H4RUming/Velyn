# Installing Velyn v1

Velyn v1 requires **iOS 27 or later**. The release IPA is an arm64 iPhone build with the local models included.

## AltStore Classic

Use **AltStore Classic**, the version that supports importing IPA files. AltStore PAL is a separate marketplace and does not import this IPA. See the [official comparison](https://github.com/altstoreio/FAQ/blob/main/altstore-pal/what-is-altstore-pal.md).

1. Set up AltServer on your Mac or Windows computer and install AltStore Classic on your iPhone using the [official setup guide](https://faq.altstore.io/).
2. Download `Velyn-1.0.0-unsigned.ipa` from the [v1.0.0 release](https://github.com/H4RUming/Velyn/releases/tag/v1.0.0) and save it to Files on your iPhone.
3. Import that IPA in AltStore Classic and follow its signing and installation prompts with your own Apple Account. Enable Developer Mode if prompted.
4. Keep AltServer available when installing or refreshing apps, either over the same Wi-Fi network or a USB connection. See [AltServer's connection requirements](https://faq.altstore.io/altstore-classic/altserver).

A free Apple Account can be used. Free-account installations expire after **7 days**, so refresh them before expiry. Apple's free signing limits allow **3 active sideloaded apps**, including AltStore itself. See [AltStore's app and refresh guide](https://faq.altstore.io/altstore-classic/your-altstore).

This is a signing workflow supported by AltStore's documentation. Velyn v1 has not yet been installed through AltStore in our device checks; compatibility with your AltStore/iOS version and account still needs confirmation.

## Apple Configurator for Mac

**Sign the IPA for your device first.** Configurator installs the signed package; it does not turn this unsigned download into a freely installable app. The app needs a valid signing certificate, provisioning profile, and matching entitlements. See [Apple's signing and export instructions](https://help.apple.com/xcode/mac/current/en.lproj/dev23ea8b877.html).

Once you have a valid signed IPA:

1. Connect and unlock your iPhone, and trust the Mac.
2. Select the device in Apple Configurator.
3. Choose **Add → Apps → Choose from my Mac**, select your signed IPA, and click **Add Apps**.

See [Apple's Configurator instructions](https://support.apple.com/guide/apple-configurator-mac/add-apps-to-a-device-cad4cd08c03/mac). Signing and device restrictions still apply. If you do not already have a signing workflow, use AltStore Classic or the Xcode path below.

## Build with Xcode

This is the documented installation path for developers. Use Xcode 27 on a Mac.

```sh
git clone --branch v1.0.0 --depth 1 https://github.com/H4RUming/Velyn.git
cd Velyn
cp Config/Local.xcconfig.example Config/Local.xcconfig
open Velyn.xcodeproj
```

1. Fill in `DEVELOPMENT_TEAM` and a unique `PRODUCT_BUNDLE_IDENTIFIER` in `Config/Local.xcconfig`. This file stays outside Git.
2. Connect your iPhone, trust the Mac, and enable Developer Mode when iOS requests it.
3. Select the `Velyn` scheme and your iPhone as the destination. Let Xcode manage signing, then run the app.

Your signing account and provisioning profile determine which devices can run the app and how long the installation remains valid.

## Signing and updates

The public IPA contains the compiled app and bundled models, with no personal provisioning profile or app signature. Its bundle ID before signing is `com.h4ruming.velyn`. Some signing workflows replace it.

Keep the bundle ID and signing identity consistent for updates. A differently signed installation may not replace an existing development build or share its data. We validated the archive and a separately signed Xcode installation; the AltStore and Configurator paths have not been tested end to end for this release.

## Verify the download

Download the IPA and `SHA256SUMS.txt` into the same folder, then run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## Reproduce the IPA

From a clean checkout with Xcode 27 selected:

```sh
./Scripts/package-release.sh 1.0.0
```

The script creates `.work/releases/v1.0.0/`, builds an unsigned Release archive with the public bundle ID, checks the bundled resources, and packages the app in `Payload/Velyn.app`. It refuses to overwrite an existing output directory. Build timestamps and toolchain versions can change the resulting checksum.

## Keep a separate copy of your photos

Velyn's internal photo storage is excluded from system backups. Export or retain your originals separately before deleting the app, changing bundle IDs, or moving to another installation. Installing an update is not a backup.
