import 'dart:async';

import 'package:flutter/material.dart' hide Animation;
import 'package:permission_handler/permission_handler.dart';
import 'package:yandex_maps_mapkit/directions.dart';
import 'package:yandex_maps_mapkit/mapkit.dart' hide Icon, TextStyle;
import 'package:yandex_maps_mapkit/mapkit_factory.dart';
import 'package:yandex_maps_mapkit/search.dart';
import 'package:yandex_maps_mapkit/transport.dart';
import 'package:yandex_maps_mapkit/yandex_map.dart';

/// Способ передвижения.
enum TravelMode { car, transit, walk }

/// Какое поле сейчас заполняем (и что выбирается нажатием на карту).
enum PickTarget { from, to }

/// Найденное место: название, описание, координаты.
class _Place {
  _Place(this.name, this.description, this.point);
  final String name;
  final String? description;
  final Point point;
}

/// Один шаг маршрута в списке внизу.
class _Step {
  _Step(this.icon, this.color, this.title, [this.subtitle]);
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  MapWindow? _mapWindow;
  UserLocationLayer? _userLocationLayer;
  TrafficLayer? _trafficLayer;

  late final DrivingRouter _drivingRouter =
      DirectionsFactory.instance.createDrivingRouter(DrivingRouterType.Combined);
  late final MasstransitRouter _masstransitRouter =
      TransportFactory.instance.createMasstransitRouter();
  late final PedestrianRouter _pedestrianRouter =
      TransportFactory.instance.createPedestrianRouter();
  late final SearchManager _searchManager =
      SearchFactory.instance.createSearchManager(SearchManagerType.Combined);

  // Сессии надо хранить в полях, иначе запрос отменится.
  DrivingSession? _drivingSession;
  MasstransitSession? _transitSession;
  SearchSession? _searchSession;
  SearchSession? _reverseSession;

  late final _TapListener _tapListener = _TapListener(_onMapTap);
  Timer? _fixTimer;

  final _fromCtl = TextEditingController();
  final _toCtl = TextEditingController();
  final _fromFocus = FocusNode();
  final _toFocus = FocusNode();

  TravelMode _mode = TravelMode.car;
  PickTarget _pick = PickTarget.from;
  bool _trafficOn = true;
  bool _loading = false;
  bool _searching = false;

  Point? _from;
  Point? _to;
  bool _fromIsMyLocation = false;

  List<_Place> _results = [];
  String? _summary;
  List<_Step> _steps = [];

  static const _startPoint = Point(latitude: 55.751244, longitude: 37.618423);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fromFocus.addListener(() {
      if (_fromFocus.hasFocus) setState(() => _pick = PickTarget.from);
    });
    _toFocus.addListener(() {
      if (_toFocus.hasFocus) setState(() => _pick = PickTarget.to);
    });
    mapkit.onStart();
    _requestLocationPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fixTimer?.cancel();
    _drivingSession?.cancel();
    _transitSession?.cancel();
    _searchSession?.cancel();
    _reverseSession?.cancel();
    _fromCtl.dispose();
    _toCtl.dispose();
    _fromFocus.dispose();
    _toFocus.dispose();
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

    // Как только GPS определит позицию, один раз переносим туда камеру.
    var ticks = 0;
    _fixTimer?.cancel();
    _fixTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      ticks++;
      final pos = _currentPosition();
      if (pos != null) {
        t.cancel();
        _moveTo(pos, zoom: 14);
        _trafficLayer?.setTrafficVisible(_trafficOn);
      } else if (ticks > 60) {
        t.cancel();
      }
    });
  }

  Point? _currentPosition() => _userLocationLayer?.cameraPosition()?.target;

  void _moveTo(Point p, {double zoom = 16}) {
    _mapWindow?.map.move(
      CameraPosition(p, zoom: zoom, azimuth: 0, tilt: 0),
      animation: Animation(type: AnimationType.Smooth, duration: 0.6),
    );
  }

  void _goToMyLocation() {
    final pos = _currentPosition();
    if (pos == null) {
      _toast('Местоположение пока не определено. Подождите несколько секунд.');
      return;
    }
    _moveTo(pos);
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

  void _toggleTraffic(bool value) {
    setState(() => _trafficOn = value);
    _trafficLayer?.setTrafficVisible(value);
    _toast(value
        ? 'Пробки включены (видны в городах при масштабе города)'
        : 'Пробки выключены');
  }

  // ---------------------------------------------------------------- Адреса

  /// Поиск адреса по тексту.
  void _search(String text) {
    final window = _mapWindow;
    if (window == null || text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _results = [];
    });
    _searchSession?.cancel();
    _searchSession = _searchManager.submit(
      VisibleRegionUtils.toPolygon(window.map.visibleRegion),
      SearchOptions(searchTypes: SearchType.Geo, resultPageSize: 8),
      SearchSessionSearchListener(
        onSearchResponse: (response) {
          if (!mounted) return;
          final places = <_Place>[];
          final objects = response.collection.children
              .map((c) => c.asGeoObject())
              .whereType<GeoObject>();
          for (final o in objects) {
            final pt = o.geometry.isNotEmpty ? o.geometry.first.asPoint() : null;
            if (pt == null) continue;
            places.add(_Place(
              o.name ?? o.descriptionText ?? 'Без названия',
              o.descriptionText,
              pt,
            ));
          }
          setState(() {
            _searching = false;
            _results = places;
          });
          if (places.isEmpty) _toast('Ничего не найдено. Уточните адрес.');
        },
        onSearchError: (e) {
          if (!mounted) return;
          setState(() => _searching = false);
          _toast('Ошибка поиска: $e');
        },
      ),
      text: text,
    );
  }

  /// Определяет адрес по координатам (для нажатия на карту).
  void _reverseGeocode(Point p, PickTarget target) {
    _reverseSession?.cancel();
    _reverseSession = _searchManager.submitPoint(
      p,
      SearchOptions(searchTypes: SearchType.Geo, resultPageSize: 1),
      SearchSessionSearchListener(
        onSearchResponse: (response) {
          if (!mounted) return;
          final objects = response.collection.children
              .map((c) => c.asGeoObject())
              .whereType<GeoObject>();
          if (objects.isEmpty) return;
          final o = objects.first;
          final name = o.name ?? o.descriptionText;
          if (name == null) return;
          // Подписываем только если точка не успела смениться.
          final current = target == PickTarget.from ? _from : _to;
          if (current != p) return;
          (target == PickTarget.from ? _fromCtl : _toCtl).text = name;
        },
        onSearchError: (_) {},
      ),
      zoom: 17,
    );
  }

  void _choosePlace(_Place place) {
    final target = _pick;
    setState(() {
      if (target == PickTarget.from) {
        _from = place.point;
        _fromIsMyLocation = false;
        _fromCtl.text = place.name;
        _pick = PickTarget.to;
      } else {
        _to = place.point;
        _toCtl.text = place.name;
      }
      _results = [];
    });
    _moveTo(place.point, zoom: 15);
    _redrawMarkers();
  }

  void _onMapTap(Point point) {
    final target = _pick;
    setState(() {
      _results = [];
      if (target == PickTarget.from) {
        _from = point;
        _fromIsMyLocation = false;
        _fromCtl.text = 'Определяю адрес…';
        _pick = PickTarget.to;
      } else {
        _to = point;
        _toCtl.text = 'Определяю адрес…';
      }
    });
    _redrawMarkers();
    _reverseGeocode(point, target);
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
      _fromCtl.text = 'Моё местоположение';
      _pick = PickTarget.to;
      _results = [];
    });
    FocusScope.of(context).unfocus();
    _redrawMarkers();
  }

  // ---------------------------------------------------------------- Объекты на карте

  void _dot(Point p, Color fill, {double radius = 25}) {
    final c = _mapWindow!.map.mapObjects.addCircle(Circle(p, radius: radius));
    c.fillColor = fill;
    c.strokeColor = Colors.white;
    c.strokeWidth = 3;
  }

  void _redrawMarkers() {
    final window = _mapWindow;
    if (window == null) return;
    window.map.mapObjects.clear();
    if (_from != null) _dot(_from!, Colors.green);
    if (_to != null) _dot(_to!, Colors.red);
  }

  void _drawPolyline(
    Polyline geometry, {
    required Color color,
    double width = 6,
    bool dashed = false,
  }) {
    final window = _mapWindow;
    if (window == null) return;
    final line = window.map.mapObjects.addPolylineWithGeometry(geometry);
    line.style = LineStyle(
      strokeWidth: width,
      dashLength: dashed ? 8 : 0,
      gapLength: dashed ? 7 : 0,
    );
    line.setStrokeColor(color);
  }

  void _showWholeRoute(Polyline geometry) {
    final window = _mapWindow;
    if (window == null) return;
    final pos =
        window.map.cameraPositionForGeometry(Geometry.fromPolyline(geometry));
    window.map.move(
      pos,
      animation: Animation(type: AnimationType.Smooth, duration: 0.8),
    );
  }

  // ---------------------------------------------------------------- Маршруты

  void _buildRoute() {
    FocusScope.of(context).unfocus();
    if (_fromIsMyLocation) {
      final pos = _currentPosition();
      if (pos != null) _from = pos;
    }
    if (_from == null || _to == null) {
      _toast('Укажите, откуда и куда: введите адрес и выберите из списка, '
          'либо нажмите на карту.');
      return;
    }
    _drivingSession?.cancel();
    _transitSession?.cancel();
    _redrawMarkers();
    setState(() {
      _loading = true;
      _summary = null;
      _steps = [];
      _results = [];
    });

    final points = [
      RequestPoint(_from!, RequestPointType.Waypoint, null, null, null),
      RequestPoint(_to!, RequestPointType.Waypoint, null, null, null),
    ];

    switch (_mode) {
      case TravelMode.car:
        _requestCarRoutes(points);
      case TravelMode.transit:
        _requestTransitRoutes(points);
      case TravelMode.walk:
        _requestWalkRoutes(points);
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
          for (var i = routes.length - 1; i >= 1; i--) {
            _drawPolyline(routes[i].geometry, color: Colors.grey, width: 5);
          }
          _drawPolyline(routes[0].geometry, color: Colors.blue, width: 7);
          _showWholeRoute(routes[0].geometry);

          final w = routes[0].metadata.weight;
          setState(() {
            _loading = false;
            _summary = 'На авто: ${w.timeWithTraffic.text}, ${w.distance.text}';
            _steps = [
              _Step(
                Icons.directions_car,
                Colors.blue,
                'Время в пути с учётом пробок: ${w.timeWithTraffic.text}',
                'Расстояние: ${w.distance.text}. '
                    'Серым показаны запасные маршруты.',
              ),
            ];
          });
        },
        onDrivingRoutesError: (e) => _fail('Не удалось построить маршрут: $e'),
      ),
      points: points,
    );
  }

  void _requestTransitRoutes(List<RequestPoint> points) {
    _transitSession = _masstransitRouter.requestRoutes(
      TransitOptions(TimeOptions()),
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
          _drawTransitRoute(routes[0]);
          _showWholeRoute(routes[0].geometry);
        },
        onMasstransitRoutesError: (e) =>
            _fail('Не удалось построить маршрут: $e'),
      ),
      points: points,
    );
  }

  void _requestWalkRoutes(List<RequestPoint> points) {
    _transitSession = _pedestrianRouter.requestRoutes(
      TimeOptions(),
      const RouteOptions(FitnessOptions()),
      RouteHandler(
        onMasstransitRoutes: (routes) {
          if (!mounted) return;
          if (routes.isEmpty) {
            _fail('Пешеходный маршрут не найден.');
            return;
          }
          for (var i = routes.length - 1; i >= 1; i--) {
            _drawPolyline(routes[i].geometry, color: Colors.grey, width: 5);
          }
          _drawPolyline(routes[0].geometry,
              color: Colors.green.shade700, width: 6, dashed: true);
          _showWholeRoute(routes[0].geometry);

          final w = routes[0].metadata.weight;
          setState(() {
            _loading = false;
            _summary = 'Пешком: ${w.time.text}, ${w.walkingDistance.text}';
            _steps = [
              _Step(Icons.directions_walk, Colors.green.shade700,
                  'Пешком ${w.walkingDistance.text}', 'Время: ${w.time.text}'),
            ];
          });
        },
        onMasstransitRoutesError: (e) =>
            _fail('Не удалось построить маршрут: $e'),
      ),
      points: points,
    );
  }

  /// Рисует маршрут по участкам: пешком — пунктиром, транспорт — цветом линии.
  void _drawTransitRoute(MasstransitRoute route) {
    final steps = <_Step>[];

    for (final section in route.sections) {
      final part =
          SubpolylineHelper.subpolyline(route.geometry, section.geometry);
      final weight = section.metadata.weight;
      final transports = section.metadata.data.asVectorMasstransitTransport();

      if (transports != null && transports.isNotEmpty) {
        // ---- участок на транспорте
        final line = transports.first.line;
        final color = _lineColor(line);
        _drawPolyline(part, color: color, width: 8);

        final kind = _vehicleName(line.vehicleTypes);
        final stops = section.stops;
        String? subtitle;
        if (stops.length >= 2) {
          subtitle = 'Сядьте на остановке «${stops.first.metadata.stop.name}», '
              'выйдите на «${stops.last.metadata.stop.name}» '
              '(${weight.time.text}, остановок: ${stops.length - 1})';
          _dot(stops.first.position, color, radius: 14);
          _dot(stops.last.position, color, radius: 14);
        }
        // Если подходит несколько линий, перечисляем все номера.
        final names = transports.map((t) => t.line.name).toSet().join(', ');
        steps.add(_Step(
          _vehicleIcon(line.vehicleTypes),
          color,
          '$kind $names',
          subtitle,
        ));
      } else {
        // ---- пеший участок / переход
        _drawPolyline(part, color: Colors.blueGrey, width: 6, dashed: true);

        final isWalk = section.metadata.data.asFitness() != null ||
            section.metadata.data.asTransfer() != null;
        if (isWalk) {
          steps.add(_Step(
            Icons.directions_walk,
            Colors.blueGrey,
            'Пешком ${weight.walkingDistance.text}',
            weight.time.text,
          ));
        }
      }
    }

    final w = route.metadata.weight;
    setState(() {
      _loading = false;
      _summary = 'Транспорт: ${w.time.text}, '
          'пешком ${w.walkingDistance.text}, пересадок: ${w.transfersCount}';
      _steps = steps;
    });
  }

  Color _lineColor(MasstransitLine line) {
    final c = line.style?.color;
    if (c != null) return Color(0xFF000000 | c);
    final types = line.vehicleTypes.join(' ');
    if (types.contains('tramway')) return Colors.red;
    if (types.contains('trolleybus')) return Colors.blue;
    if (types.contains('underground')) return Colors.purple;
    if (types.contains('suburban') || types.contains('railway')) {
      return Colors.teal;
    }
    if (types.contains('minibus')) return Colors.orange;
    return Colors.green.shade700; // автобус и прочее
  }

  String _vehicleName(List<String> types) {
    const names = {
      'bus': 'Автобус',
      'trolleybus': 'Троллейбус',
      'tramway': 'Трамвай',
      'underground': 'Метро',
      'suburban': 'Электричка',
      'railway': 'Поезд',
      'minibus': 'Маршрутка',
      'ferry': 'Паром',
      'water': 'Водный транспорт',
      'cable': 'Канатная дорога',
      'funicular': 'Фуникулёр',
      'aeroexpress': 'Аэроэкспресс',
    };
    for (final t in types) {
      final n = names[t];
      if (n != null) return n;
    }
    return 'Транспорт';
  }

  IconData _vehicleIcon(List<String> types) {
    final s = types.join(' ');
    if (s.contains('tramway')) return Icons.tram;
    if (s.contains('underground')) return Icons.subway;
    if (s.contains('suburban') || s.contains('railway')) return Icons.train;
    if (s.contains('ferry') || s.contains('water')) return Icons.directions_boat;
    return Icons.directions_bus;
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _summary = null;
      _steps = [];
    });
    _toast(message);
  }

  void _clearAll() {
    _drivingSession?.cancel();
    _transitSession?.cancel();
    _searchSession?.cancel();
    _mapWindow?.map.mapObjects.clear();
    _fromCtl.clear();
    _toCtl.clear();
    setState(() {
      _from = null;
      _to = null;
      _fromIsMyLocation = false;
      _pick = PickTarget.from;
      _summary = null;
      _steps = [];
      _results = [];
      _loading = false;
      _searching = false;
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
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          YandexMap(onMapCreated: _onMapCreated),
          SafeArea(child: _buildTopPanel()),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12, bottom: 8),
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
                  if (_summary != null) _buildInfoCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text(_summary!,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _steps.length,
                itemBuilder: (_, i) {
                  final s = _steps[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: s.color,
                      child: Icon(s.icon, size: 18, color: Colors.white),
                    ),
                    title: Text(s.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: s.subtitle == null ? null : Text(s.subtitle!),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopPanel() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<TravelMode>(
                    showSelectedIcon: false,
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
                      ButtonSegment(
                        value: TravelMode.walk,
                        icon: Icon(Icons.directions_walk),
                        label: Text('Пешком'),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                  const SizedBox(height: 8),
                  _field(
                    controller: _fromCtl,
                    focus: _fromFocus,
                    label: 'Откуда',
                    icon: Icons.trip_origin,
                    color: Colors.green,
                    extra: IconButton(
                      tooltip: 'Я здесь (GPS)',
                      icon: const Icon(Icons.gps_fixed),
                      onPressed: _useMyLocationAsFrom,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _field(
                    controller: _toCtl,
                    focus: _toFocus,
                    label: 'Куда',
                    icon: Icons.place,
                    color: Colors.red,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _loading ? null : _buildRoute,
                          icon: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
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
          if (_searching) const LinearProgressIndicator(),
          if (_results.isNotEmpty)
            Card(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final p = _results[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(p.name),
                      subtitle:
                          p.description == null ? null : Text(p.description!),
                      onTap: () => _choosePlace(p),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required String label,
    required IconData icon,
    required Color color,
    Widget? extra,
  }) {
    return TextField(
      controller: controller,
      focusNode: focus,
      textInputAction: TextInputAction.search,
      onSubmitted: _search,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: 'Введите адрес или нажмите на карту',
        prefixIcon: Icon(icon, color: color),
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (extra != null) extra,
            IconButton(
              tooltip: 'Найти',
              icon: const Icon(Icons.search),
              onPressed: () => _search(controller.text),
            ),
          ],
        ),
      ),
    );
  }
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
