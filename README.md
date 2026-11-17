# Навигатор (Flutter + Яндекс MapKit)

GPS, маршрут на авто, общественный транспорт, пробки.

## 1. Развернуть проект в репозитории (Codespace)

В терминале Codespace, в корне репозитория:

```bash
flutter create . --org com.example --project-name navigator_app --platforms android
```

Затем **замените** файлы из этого архива: `pubspec.yaml` и всю папку `lib/`
(`main.dart`, `config.dart`, `screens/map_screen.dart`).

```bash
flutter pub get
```

## 2. Настройка Android

**`android/app/src/main/AndroidManifest.xml`** — внутрь `<manifest>`, перед `<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

**`android/app/build.gradle.kts`** (или `build.gradle`, если у вас Groovy):

- в `defaultConfig` поставить `minSdk = 26` (Groovy: `minSdkVersion 26`);
- добавить зависимость:

```kotlin
dependencies {
    implementation("com.google.android.gms:play-services-location:21.1.0")
}
```

(Если блока `dependencies { }` в файле нет — добавьте его в конец файла.)

## 3. API-ключ

1. https://developer.tech.yandex.ru/services/ → «Подключить API» → **MapKit Mobile SDK**.
2. Ключ начинает работать минут через 15.
3. В репозиторий ключ не кладём — передаём при запуске.

## 4. Запуск

В Codespace нет эмулятора Android и GPS, поэтому проверять нужно на телефоне:

```bash
flutter build apk --dart-define=MAPKIT_API_KEY=ВАШ_КЛЮЧ
```

APK будет в `build/app/outputs/flutter-apk/app-release.apk` — скачайте
его из Codespace (ПКМ → Download) и установите на Android-телефон.
Либо запускайте локально на своём компьютере с телефоном по USB:
`flutter run --dart-define=MAPKIT_API_KEY=ВАШ_КЛЮЧ`.

## Как пользоваться

- Сверху выберите **Авто** или **Транспорт**.
- «Откуда»: нажмите на карту или кнопку GPS справа в строке («Я здесь»).
- «Куда»: нажмите на карту.
- «Построить маршрут» — основной маршрут цветной, запасные серые, внизу время и расстояние.
- Кнопка со светофором — пробки, кнопка-прицел — к моему местоположению.

Маршруты на общественном транспорте работают только в городах, где у Яндекса есть данные.
