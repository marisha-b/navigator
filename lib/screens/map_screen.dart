import 'package:flutter/material.dart' hide Animation;
import 'package:permission_handler/permission_handler.dart';
import 'package:yandex_maps_mapkit/directions.dart';
import 'package:yandex_maps_mapkit/mapkit.dart' hide Icon, TextStyle;
import 'package:yandex_maps_mapkit/mapkit_factory.dart';
import 'package:yandex_maps_mapkit/transport.dart';
import 'package:yandex_maps_mapkit/yandex_map.dart';

/// Способ передвижения.
enum TravelMode { car, transit }

/// Какую точку сейчас выбираем нажатием на карту.
enum PickTarget { from, to }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  MapWindow? _mapWindow;
  UserLocationLayer? _userLocationLayer;
  TrafficLayer? _trafficLayer;

  // Маршрутизаторы создаются один раз.
  late final DrivingRouter _drivingRouter =
      DirectionsFactory.instance.createDrivingRouter(DrivingRouterType.Combined);
  late final MasstransitRouter _masstransitRouter =
      TransportFactory.instance.createMasstransitRouter();

  // ВАЖНО: сессию надо хранить в поле, иначе запрос маршрута отменится.
  DrivingSession? _drivingSession;
  MasstransitSession? _transitSession;

  late final _TapListener _tapListener = _TapListener(_onMapTap);

  TravelMode _mode = TravelMode.car;
  PickTarget _pick = PickTarget.from;
  bool _trafficOn = true;
  bool _loading = false;

  Point? _from;
  Point? _to;
  bool _fromIsMyLocation = false;

  String? _info;

  // Начальная точка камеры (Москва), пока нет GPS.
  static const _startPoint = Point(latitude: 55.751244, longitude: 37.618423);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    mapkit.onStart();
    _requestLocationPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _drivingSession?.cancel();
    _transitSession?.cancel();
    mapkit.onStop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      mapkit.onStart();
    } else if (state == AppLifecycleState.paused) {
      mapkit.onStop();
    }
  }

  // ---------------------------------------------------------------- GPS

  Future<void> _requestLocationPermission() async {
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      _toast('Нет доступа к геолокации. Включите его в настройках.');
      return;
    }
    _enableUserLocation();
  }

  void _enableUserLocation() {
    final window = _mapWindow;
    if (window == null || _userLocationLayer != null) return;
    final layer = mapkit.createUserLocationLayer(window);
    layer.setVisible(true);
    _userLocationLayer = layer;
  }

  /// Текущая GPS-позиция или null, если ещё не определена.
  Point? _currentPosition() => _userLocationLayer?.cameraPosition()?.target;

  void _goToMyLocation() {
    final pos = _currentPosition();
    if (pos == null) {
      _toast('Местоположение пока не определено. Подождите несколько секунд.');
      return;
    }
    _mapWindow?.map.move(
      CameraPosition(pos, zoom: 16, azimuth: 0, tilt: 0),
      animation: Animation(type: AnimationType.Smooth, duration: 0.6),
    );
  }

  // ---------------------------------------------------------------- Карта

  void _onMapCreated(MapWindow window) {
    _mapWindow = window;
    window.map.move(
      CameraPosition(_startPoint, zoom: 10, azimuth: 0, tilt: 0),
    );
    window.map.addInputListener(_tapListener);

    _trafficLayer = mapkit.createTrafficLayer(window);
    _trafficLayer!.setTrafficVisible(_trafficOn);

    _enableUserLocation();
  }

  void _onMapTap(Point point) {
    setState(() {
      if (_pick == PickTarget.from) {
        _from = point;
        _fromIsMyLocation = false;
        _pick = PickTarget.to; // после «откуда» сразу выбираем «куда»
      } else {
        _to = point;
      }
    });
    _redrawMarkers();
  }

  void _useMyLocationAsFrom() {
    final pos = _currentPosition();
    if (pos == null) {
      _toast('Местоположение пока не определено.');
      return;
    }
    setState(() {
      _from = pos;
      _fromIsMyLocation = true;
      _pick = PickTarget.to;
    });
    _redrawMarkers();
  }

  void _toggleTraffic(bool value) {
    setState(() => _trafficOn = value);
    _trafficLayer?.setTrafficVisible(value);
  }

  // ---------------------------------------------------------------- Объекты на карте

  void _redrawMarkers() {
    final window = _mapWindow;
    if (window == null) return;
    final objects = window.map.mapObjects;
    objects.clear();

    void dot(Point p, Color color) {
      final c = objects.addCircle(Circle(p, radius: 25));
      c.fillColor = color;
      c.strokeColor = Colors.white;
      c.strokeWidth = 3;
    }

    if (_from != null) dot(_from!, Colors.green);
    if (_to != null) dot(_to!, Colors.red);
  }

  void _drawPolyline(Polyline geometry, {required Color color, double width = 6}) {
    final window = _mapWindow;
    if (window == null) return;
    final line = window.map.mapObjects.addPolylineWithGeometry(geometry);
    line.setStrokeColor(color);
    line.strokeWidth = width;
  }

  void _showWholeRoute(Polyline geometry) {
    final window = _mapWindow;
    if (window == null) return;
    final pos = window.map.cameraPositionForGeometry(Geometry.fromPolyline(geometry));
    window.map.move(
      pos,
      animation: Animation(type: AnimationType.Smooth, duration: 0.8),
    );
  }

  // ---------------------------------------------------------------- Маршруты

  void _buildRoute() {
    if (_fromIsMyLocation) {
      // обновим стартовую точку по свежему GPS
      final pos = _currentPosition();
      if (pos != null) _from = pos;
    }
    if (_from == null || _to == null) {
      _toast('Укажите, откуда и куда едете.');
      return;
    }
    _drivingSession?.cancel();
    _transitSession?.cancel();
    _redrawMarkers();
    setState(() {
      _loading = true;
      _info = null;
    });

    final points = [
      RequestPoint(_from!, RequestPointType.Waypoint, null, null, null),
      RequestPoint(_to!, RequestPointType.Waypoint, null, null, null),
    ];

    if (_mode == TravelMode.car) {
      _requestCarRoutes(points);
    } else {
      _requestTransitRoutes(points);
    }
  }

  void _requestCarRoutes(List<RequestPoint> points) {
    _drivingSession = _drivingRouter.requestRoutes(
      DrivingOptions(routesCount: 3),
      DrivingVehicleOptions(),
      DrivingSessionRouteListener(
        onDrivingRoutes: (routes) {
          if (!mounted) return;
          if (routes.isEmpty) {
            _fail('Маршрут не найден.');
            return;
          }
          // Сначала запасные (серые), поверх — основной.
          for (var i = routes.length - 1; i >= 1; i--) {
            _drawPolyline(routes[i].geometry, color: Colors.grey, width: 5);
          }
          _drawPolyline(routes[0].geometry, color: Colors.blue, width: 7);
          _showWholeRoute(routes[0].geometry);

          final w = routes[0].metadata.weight;
          setState(() {
            _loading = false;
            _info = 'На авто: ${w.timeWithTraffic.text}, ${w.distance.text}';
          });
        },
        onDrivingRoutesError: (e) => _fail('Не удалось построить маршрут: $e'),
      ),
      points: points,
    );
  }

  void _requestTransitRoutes(List<RequestPoint> points) {
    _transitSession = _masstransitRouter.requestRoutes(
      TransitOptions(TimeOptions()), // без привязки ко времени = «выехать сейчас»
      const RouteOptions(FitnessOptions()),
      RouteHandler(
        onMasstransitRoutes: (routes) {
          if (!mounted) return;
          if (routes.isEmpty) {
            _fail('Маршрут на общественном транспорте не найден.');
            return;
          }
          for (var i = routes.length - 1; i >= 1; i--) {
            _drawPolyline(routes[i].geometry, color: Colors.grey, width: 5);
          }
          _drawPolyline(routes[0].geometry, color: Colors.deepPurple, width: 7);
          _showWholeRoute(routes[0].geometry);

          final w = routes[0].metadata.weight;
          setState(() {
            _loading = false;
            _info = 'Транспорт: ${w.time.text}, '
                'пешком ${w.walkingDistance.text}, '
                'пересадок: ${w.transfersCount}';
          });
        },
        onMasstransitRoutesError: (e) =>
            _fail('Не удалось построить маршрут: $e'),
      ),
      points: points,
    );
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _info = null;
    });
    _toast(message);
  }

  void _clearAll() {
    _drivingSession?.cancel();
    _transitSession?.cancel();
    _mapWindow?.map.mapObjects.clear();
    setState(() {
      _from = null;
      _to = null;
      _fromIsMyLocation = false;
      _pick = PickTarget.from;
      _info = null;
      _loading = false;
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          YandexMap(onMapCreated: _onMapCreated),
          SafeArea(child: _buildTopPanel()),
          Positioned(
            right: 12,
            bottom: 24 + (_info != null ? 70 : 0),
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'traffic',
                  backgroundColor: _trafficOn ? Colors.orange : null,
                  onPressed: () => _toggleTraffic(!_trafficOn),
                  child: const Icon(Icons.traffic),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'gps',
                  onPressed: _goToMyLocation,
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ),
          if (_info != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 16,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(_info!, style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopPanel() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<TravelMode>(
                segments: const [
                  ButtonSegment(
                    value: TravelMode.car,
                    icon: Icon(Icons.directions_car),
                    label: Text('Авто'),
                  ),
                  ButtonSegment(
                    value: TravelMode.transit,
                    icon: Icon(Icons.directions_bus),
                    label: Text('Транспорт'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 8),
              _pointRow(
                icon: Icons.trip_origin,
                color: Colors.green,
                label: 'Откуда',
                text: _fromIsMyLocation
                    ? 'Моё местоположение'
                    : _from == null
                        ? 'Нажмите на карту'
                        : _fmt(_from!),
                selected: _pick == PickTarget.from,
                onTap: () => setState(() => _pick = PickTarget.from),
                trailing: IconButton(
                  tooltip: 'Я здесь (GPS)',
                  icon: const Icon(Icons.gps_fixed),
                  onPressed: _useMyLocationAsFrom,
                ),
              ),
              _pointRow(
                icon: Icons.place,
                color: Colors.red,
                label: 'Куда',
                text: _to == null ? 'Нажмите на карту' : _fmt(_to!),
                selected: _pick == PickTarget.to,
                onTap: () => setState(() => _pick = PickTarget.to),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _buildRoute,
                      icon: _loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.alt_route),
                      label: const Text('Построить маршрут'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _clearAll,
                    child: const Text('Сброс'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pointRow({
    required IconData icon,
    required Color color,
    required String label,
    required String text,
    required bool selected,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
            Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  String _fmt(Point p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';
}

// -------------------------------------------------------------------- слушатели

class _TapListener implements MapInputListener {
  _TapListener(this._onTap);
  final void Function(Point) _onTap;

  @override
  void onMapTap(Map map, Point point) => _onTap(point);

  @override
  void onMapLongTap(Map map, Point point) => _onTap(point);
}
