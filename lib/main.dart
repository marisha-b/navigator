import 'package:flutter/material.dart';
import 'package:yandex_maps_mapkit/init.dart' as init;

import 'config.dart';
import 'screens/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kMapkitApiKey.isEmpty) {
    runApp(const _MissingKeyApp());
    return;
  }

  // Загружает нативные библиотеки MapKit и задаёт API-ключ.
  await init.initMapkit(apiKey: kMapkitApiKey);

  runApp(const NavigatorApp());
}

class NavigatorApp extends StatelessWidget {
  const NavigatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Навигатор',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

class _MissingKeyApp extends StatelessWidget {
  const _MissingKeyApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Не задан API-ключ MapKit.\n\n'
              'Запустите приложение так:\n'
              'flutter run --dart-define=MAPKIT_API_KEY=ваш_ключ',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
