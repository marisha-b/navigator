#!/usr/bin/env bash
# Автоматически настраивает Android-часть проекта. Запускать из корня проекта ПОСЛЕ flutter create.
set -e

MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q ACCESS_FINE_LOCATION "$MANIFEST"; then
  sed -i '0,/<manifest[^>]*>/s//&\n    <uses-permission android:name="android.permission.INTERNET"\/>\n    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"\/>\n    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"\/>/' "$MANIFEST"
fi

GRADLE=$(ls android/app/build.gradle.kts android/app/build.gradle 2>/dev/null | head -n1)
sed -i -E 's/minSdk(Version)?( =|)? *flutter\.minSdkVersion/minSdk = 26/' "$GRADLE"
sed -i -E 's/minSdkVersion +flutter\.minSdkVersion/minSdkVersion 26/' "$GRADLE"
if ! grep -q play-services-location "$GRADLE"; then
  printf '\ndependencies {\n    implementation("com.google.android.gms:play-services-location:21.1.0")\n}\n' >> "$GRADLE"
fi
echo "Готово: $MANIFEST и $GRADLE настроены"
grep -n "minSdk" "$GRADLE" || true
