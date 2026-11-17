/// API-ключ MapKit передаётся при запуске, чтобы не хранить его в репозитории:
///
///   flutter run --dart-define=MAPKIT_API_KEY=ваш_ключ
///
/// Ключ создаётся на https://developer.tech.yandex.ru/services/
/// (сервис "MapKit Mobile SDK"). После создания ключ активируется ~15 минут.
const String kMapkitApiKey = String.fromEnvironment('MAPKIT_API_KEY');
