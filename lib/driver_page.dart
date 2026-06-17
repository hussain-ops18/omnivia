import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

////////////////////////////////////////////////////////////
/// OMNIVIA DRIVER AI — CAR DASHBOARD
/// • Circular fuel gauge (dashboard style)
/// • Live map with route tracking
/// • Fuel station pins on map
/// • Low fuel popup alert
/// • OBD2 auto fuel fetch
/// • Vehicle search + mileage
/// • Terrain auto detect
////////////////////////////////////////////////////////////

// ── Colors ────────────────────────────────────────────────
const kBg         = Color(0xFF0A0A0F);
const kCard       = Color(0xFF12121A);
const kAccent     = Color(0xFFFF6B00);
const kAccent2    = Color(0xFF00D4FF);
const kGreen      = Color(0xFF00FF88);
const kRed        = Color(0xFFFF3355);
const kYellow     = Color(0xFFFFD600);

// ── Terrain ───────────────────────────────────────────────
enum TerrainType { city, town, highway, expressway, ghat }

extension TerrainExt on TerrainType {
  String get emoji {
    switch (this) {
      case TerrainType.city:       return '🏙️';
      case TerrainType.town:       return '🏘️';
      case TerrainType.highway:    return '🛣️';
      case TerrainType.expressway: return '🚀';
      case TerrainType.ghat:       return '⛰️';
    }
  }
  String get label {
    switch (this) {
      case TerrainType.city:       return 'City';
      case TerrainType.town:       return 'Town';
      case TerrainType.highway:    return 'Highway';
      case TerrainType.expressway: return 'Expressway';
      case TerrainType.ghat:       return 'Ghat Road';
    }
  }
  double get factor {
    switch (this) {
      case TerrainType.city:       return 0.70;
      case TerrainType.town:       return 0.85;
      case TerrainType.highway:    return 1.00;
      case TerrainType.expressway: return 1.05;
      case TerrainType.ghat:       return 0.60;
    }
  }
}

////////////////////////////////////////////////////////////
class DriverPage extends StatefulWidget {
  const DriverPage({super.key});
  @override
  State<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends State<DriverPage>
    with TickerProviderStateMixin {

  // ── Animation ─────────────────────────────────────────
  late AnimationController _gaugeController;
  late Animation<double>   _gaugeAnimation;
  double _gaugeTarget = 0;

  // ── Vehicle ───────────────────────────────────────────
  final _searchCtrl      = TextEditingController();
  final _fuelCtrl        = TextEditingController();
  String  _vehicleName   = '';
  double  _officialKmpl  = 0;
  String  _fuelType      = 'Petrol';
  int     _tankCapacity  = 40;
  List<Map<String, dynamic>> _searchResults = [];
  bool    _searching     = false;

  // ── Fuel ──────────────────────────────────────────────
  double _fuelLitres     = 0;
  double _fuelPercent    = 0;
  bool   _lowFuelAlerted = false;

  // ── OBD2 ─────────────────────────────────────────────
  bool   _obd2Connected  = false;
  BluetoothDevice? _obd2Device;
  BluetoothCharacteristic? _obd2Char;
  List<BluetoothDevice> _btDevices = [];
  String _obd2Status     = 'Not Connected';
  String _currentPID     = '';
  double _obd2Rpm        = 0;
  double _obd2Speed      = 0;

  // ── GPS / Map ─────────────────────────────────────────
  final MapController _mapCtrl = MapController();
  LatLng?  _userPos;
  List<LatLng> _routePoints   = [];
  StreamSubscription? _posStream;
  double   _gpsSpeed          = 0;
  double   _gpsAlt            = 0;
  double   _prevAlt           = 0;
  int      _stopCount         = 0;
  TerrainType _terrain        = TerrainType.highway;

  // ── Fuel Stations ─────────────────────────────────────
  List<Map<String, dynamic>> _fuelStations = [];
  bool _stationsLoaded = false;

  // ── Results ───────────────────────────────────────────
  double _range          = 0;
  double _adjustedKmpl   = 0;
  String _riskLevel      = 'SAFE';
  Color  _riskColor      = kGreen;

  // ── UI State ──────────────────────────────────────────
  bool _showSearch       = false;
  bool _isOnline         = false;

  ////////////////////////////////////////////////////////////
  @override
  void initState() {
    super.initState();
    _gaugeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _gaugeAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _gaugeController, curve: Curves.easeOutCubic),
    );
    _checkConnectivity();
    _startGPS();
  }

  // ── Animate gauge ─────────────────────────────────────
  void _animateGauge(double target) {
    final old = _gaugeTarget;
    _gaugeTarget = target;
    _gaugeAnimation = Tween<double>(begin: old, end: target).animate(
      CurvedAnimation(parent: _gaugeController, curve: Curves.easeOutCubic),
    );
    _gaugeController.forward(from: 0);
  }

  ////////////////////////////////////////////////////////////
  // CONNECTIVITY
  ////////////////////////////////////////////////////////////
  Future<void> _checkConnectivity() async {
    final r = await Connectivity().checkConnectivity();
    setState(() => _isOnline = r != ConnectivityResult.none);
  }

  ////////////////////////////////////////////////////////////
  // GPS
  ////////////////////////////////////////////////////////////
  void _startGPS() async {
    LocationPermission perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied) return;

    _posStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((pos) {
      final spd = (pos.speed * 3.6).clamp(0.0, 200.0);
      final alt = pos.altitude;
      final ll  = LatLng(pos.latitude, pos.longitude);

      if (spd < 2) _stopCount++;
      else _stopCount = (_stopCount - 1).clamp(0, 999);

      // Terrain detect
      final altDiff = (alt - _prevAlt).abs();
      TerrainType t;
      if (altDiff > 15 && spd < 50)    t = TerrainType.ghat;
      else if (spd > 100)               t = TerrainType.expressway;
      else if (spd >= 60 && _stopCount < 3) t = TerrainType.highway;
      else if (spd >= 30 && _stopCount < 10) t = TerrainType.town;
      else                              t = TerrainType.city;

      setState(() {
        _gpsSpeed  = spd;
        _gpsAlt    = alt;
        _prevAlt   = alt;
        _terrain   = t;
        _userPos   = ll;
        _routePoints.add(ll);
        if (_routePoints.length > 500) _routePoints.removeAt(0);
      });

      // Move map
      try { _mapCtrl.move(ll, _mapCtrl.camera.zoom); } catch (_) {}

      // Fetch stations when first location available
      if (!_stationsLoaded) {
        _stationsLoaded = true;
        _fetchFuelStations();
      }

      _calculate();
    });
  }

  ////////////////////////////////////////////////////////////
  // VEHICLE SEARCH
  ////////////////////////////////////////////////////////////
  Future<void> _searchVehicle(String q) async {
    if (q.length < 2) return;
    setState(() => _searching = true);

    try {
      final url = Uri.parse('https://indian-auto-api.vercel.app/cars?model=$q');
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _searchResults = (data is List ? data : [data])
              .cast<Map<String, dynamic>>();
          _searching = false;
        });
        return;
      }
    } catch (_) {}

    // Local fallback
    final query = q.toLowerCase();
    setState(() {
      _searchResults = _localDB
          .where((v) =>
              v['model'].toLowerCase().contains(query) ||
              v['brand'].toLowerCase().contains(query))
          .toList();
      _searching = false;
    });
  }

  void _selectVehicle(Map<String, dynamic> v) {
    final kmpl = double.tryParse(
            (v['mileage'] ?? v['kmpl'] ?? '15').toString()
                .replaceAll(' kmpl', '')) ??
        15;
    setState(() {
      _vehicleName  = '${v['brand name'] ?? v['brand']} ${v['model name'] ?? v['model']}';
      _officialKmpl = kmpl;
      _fuelType     = v['fuel type'] ?? v['fuel'] ?? 'Petrol';
      _tankCapacity = int.tryParse((v['tank'] ?? '40').toString()) ?? 40;
      _searchResults = [];
      _showSearch    = false;
      _searchCtrl.text = _vehicleName;
    });
    _calculate();
  }

  // Local DB
  final List<Map<String, dynamic>> _localDB = [
    {'brand':'Maruti','model':'Swift',         'kmpl':23.2,'fuel':'Petrol','tank':37},
    {'brand':'Maruti','model':'Swift Dzire',   'kmpl':23.26,'fuel':'Petrol','tank':37},
    {'brand':'Maruti','model':'Alto K10',      'kmpl':24.9,'fuel':'Petrol','tank':35},
    {'brand':'Maruti','model':'Baleno',        'kmpl':22.9,'fuel':'Petrol','tank':37},
    {'brand':'Maruti','model':'Ertiga',        'kmpl':20.3,'fuel':'Petrol','tank':45},
    {'brand':'Maruti','model':'Brezza',        'kmpl':19.8,'fuel':'Petrol','tank':48},
    {'brand':'Hyundai','model':'i20',          'kmpl':20.3,'fuel':'Petrol','tank':37},
    {'brand':'Hyundai','model':'Creta',        'kmpl':17.4,'fuel':'Petrol','tank':50},
    {'brand':'Hyundai','model':'Venue',        'kmpl':18.15,'fuel':'Petrol','tank':45},
    {'brand':'Toyota','model':'Innova Crysta', 'kmpl':15.1,'fuel':'Diesel','tank':65},
    {'brand':'Toyota','model':'Fortuner',      'kmpl':12.0,'fuel':'Diesel','tank':80},
    {'brand':'Tata',  'model':'Nexon',         'kmpl':17.01,'fuel':'Petrol','tank':44},
    {'brand':'Tata',  'model':'Punch',         'kmpl':18.8,'fuel':'Petrol','tank':40},
    {'brand':'Honda', 'model':'Activa 6G',     'kmpl':60.0,'fuel':'Petrol','tank':5},
    {'brand':'Bajaj', 'model':'Pulsar 150',    'kmpl':50.0,'fuel':'Petrol','tank':15},
    {'brand':'TVS',   'model':'Apache RTR 160','kmpl':45.0,'fuel':'Petrol','tank':12},
    {'brand':'Royal Enfield','model':'Bullet 350','kmpl':36.2,'fuel':'Petrol','tank':13},
    {'brand':'Mahindra','model':'Scorpio N',   'kmpl':15.2,'fuel':'Diesel','tank':60},
    {'brand':'Kia',   'model':'Seltos',        'kmpl':16.5,'fuel':'Petrol','tank':50},
    {'brand':'Renault','model':'Kwid',         'kmpl':22.3,'fuel':'Petrol','tank':28},
  ];

  ////////////////////////////////////////////////////////////
  // OBD2
  ////////////////////////////////////////////////////////////
  Future<void> _scanBT() async {
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      final results = FlutterBluePlus.lastScanResults;
      setState(() {
        _btDevices = results
            .where((r) => r.device.platformName.isNotEmpty)
            .map((r) => r.device)
            .toList();
      });
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  Future<void> _connectOBD2(BluetoothDevice device) async {
    setState(() => _obd2Status = 'Connecting...');
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      final services = await device.discoverServices();
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.properties.write && c.properties.notify) {
            _obd2Char = c;
            await c.setNotifyValue(true);
            c.lastValueStream.listen(_onOBD2Data);
            break;
          }
        }
      }
      setState(() {
        _obd2Device    = device;
        _obd2Connected = true;
        _obd2Status    = '✅ ${device.platformName}';
      });
      await _sendOBD2('ATZ\r');
      await Future.delayed(const Duration(milliseconds: 500));
      await _sendOBD2('ATE0\r');
      await _sendOBD2('ATSP0\r');
      _pollOBD2();
    } catch (_) {
      setState(() => _obd2Status = '❌ Failed');
    }
  }

  Future<void> _sendOBD2(String cmd) async {
    if (_obd2Char == null) return;
    await _obd2Char!.write(utf8.encode(cmd));
  }

  void _onOBD2Data(List<int> data) {
    final r = utf8.decode(data).replaceAll(' ', '').trim();
    try {
      if (_currentPID == '012F' && r.length >= 6) {
        final a = int.parse(r.substring(4, 6), radix: 16);
        final pct = (a * 100) / 255;
        final litres = (pct / 100) * _tankCapacity;
        setState(() {
          _fuelPercent = pct;
          _fuelLitres  = litres;
        });
        _animateGauge(pct / 100);
        _checkLowFuel();
        _calculate();
      } else if (_currentPID == '010C' && r.length >= 8) {
        final a = int.parse(r.substring(4, 6), radix: 16);
        final b = int.parse(r.substring(6, 8), radix: 16);
        setState(() => _obd2Rpm = ((a * 256) + b) / 4);
      } else if (_currentPID == '010D' && r.length >= 6) {
        final a = int.parse(r.substring(4, 6), radix: 16);
        setState(() => _obd2Speed = a.toDouble());
      }
    } catch (_) {}
  }

  void _pollOBD2() {
    Timer.periodic(const Duration(seconds: 4), (t) async {
      if (!_obd2Connected) { t.cancel(); return; }
      _currentPID = '012F';
      await _sendOBD2('012F\r');
      await Future.delayed(const Duration(milliseconds: 800));
      _currentPID = '010C';
      await _sendOBD2('010C\r');
      await Future.delayed(const Duration(milliseconds: 800));
      _currentPID = '010D';
      await _sendOBD2('010D\r');
    });
  }

  Future<void> _disconnectOBD2() async {
    await _obd2Device?.disconnect();
    setState(() {
      _obd2Connected = false;
      _obd2Device    = null;
      _obd2Char      = null;
      _obd2Status    = 'Disconnected';
      _obd2Rpm       = 0;
      _obd2Speed     = 0;
    });
  }

  ////////////////////////////////////////////////////////////
  // FUEL STATIONS — Overpass API
  ////////////////////////////////////////////////////////////
  Future<void> _fetchFuelStations() async {
    if (_userPos == null) return;
    try {
      final query = '''
[out:json][timeout:15];
node["amenity"="fuel"](around:10000,${_userPos!.latitude},${_userPos!.longitude});
out 8;
''';
      final res = await http
          .post(Uri.parse('https://overpass-api.de/api/interpreter'), body: query)
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data  = jsonDecode(res.body);
        final elems = data['elements'] as List;
        final List<Map<String, dynamic>> stations = [];

        for (final el in elems) {
          final tags = el['tags'] ?? {};
          final lat  = (el['lat'] as num).toDouble();
          final lon  = (el['lon'] as num).toDouble();
          final dist = _userPos != null
              ? Geolocator.distanceBetween(
                      _userPos!.latitude, _userPos!.longitude, lat, lon) /
                  1000
              : 0.0;
          stations.add({
            'name': tags['name'] ?? tags['operator'] ?? tags['brand'] ?? 'Fuel Station',
            'lat': lat,
            'lon': lon,
            'dist': dist,
            'brand': tags['brand'] ?? '',
          });
        }
        stations.sort((a, b) => (a['dist'] as double).compareTo(b['dist'] as double));
        setState(() => _fuelStations = stations);
        return;
      }
    } catch (_) {}

    // Fallback
    if (_userPos != null) {
      setState(() => _fuelStations = [
        {'name': 'Indian Oil', 'lat': _userPos!.latitude + 0.03, 'lon': _userPos!.longitude + 0.02, 'dist': 4.2, 'brand': 'IOC'},
        {'name': 'HP Petrol Bunk', 'lat': _userPos!.latitude - 0.02, 'lon': _userPos!.longitude + 0.04, 'dist': 6.8, 'brand': 'HP'},
        {'name': 'Bharat Petroleum', 'lat': _userPos!.latitude + 0.05, 'lon': _userPos!.longitude - 0.03, 'dist': 9.1, 'brand': 'BPCL'},
      ]);
    }
  }

  ////////////////////////////////////////////////////////////
  // LOW FUEL CHECK
  ////////////////////////////////////////////////////////////
  void _checkLowFuel() {
    if (_fuelPercent <= 20 && !_lowFuelAlerted) {
      _lowFuelAlerted = true;
      HapticFeedback.heavyImpact();
      _showLowFuelPopup();
    }
    if (_fuelPercent > 25) _lowFuelAlerted = false;
  }

  void _showLowFuelPopup() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: kRed, width: 2),
            boxShadow: [
              BoxShadow(color: kRed.withOpacity(0.3), blurRadius: 30, spreadRadius: 5),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('⛽', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              const Text('LOW FUEL!',
                  style: TextStyle(
                      color: kRed,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3)),
              const SizedBox(height: 8),
              Text(
                'Only ${_fuelPercent.toStringAsFixed(0)}% fuel remaining\n'
                '${_fuelLitres.toStringAsFixed(1)}L left — '
                '~${_range.toStringAsFixed(0)} km range',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              if (_fuelStations.isNotEmpty)
                Text(
                  'Nearest: ${_fuelStations.first['name']} — ${(_fuelStations.first['dist'] as double).toStringAsFixed(1)} km',
                  style: const TextStyle(color: kYellow, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Dismiss',
                          style: TextStyle(color: Colors.white38)),
                    ),
                  ),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        if (_fuelStations.isNotEmpty) {
                          final s = _fuelStations.first;
                          final uri = Uri.parse(
                              'https://www.google.com/maps/dir/?api=1&destination=${s['lat']},${s['lon']}');
                          if (await canLaunchUrl(uri)) launchUrl(uri);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                          backgroundColor: kRed,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                      child: const Text('Navigate!'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  ////////////////////////////////////////////////////////////
  // CALCULATE
  ////////////////////////////////////////////////////////////
  void _calculate() {
    if (_officialKmpl == 0) return;

    final spd = _obd2Connected ? _obd2Speed : _gpsSpeed;
    double speedFactor = spd > 100 ? 0.85 : spd > 70 ? 0.92 : 1.0;
    double altFactor   = 1.0;
    final altDiff = _gpsAlt - _prevAlt;
    if (altDiff > 50)       altFactor = 0.75;
    else if (altDiff > 20)  altFactor = 0.88;
    else if (altDiff < -20) altFactor = 1.10;

    _adjustedKmpl = _officialKmpl * _terrain.factor * speedFactor * altFactor;
    _range        = _fuelLitres * _adjustedKmpl;

    if (_range < 30) {
      _riskLevel = 'CRITICAL';
      _riskColor = kRed;
    } else if (_range < 80) {
      _riskLevel = 'LOW RANGE';
      _riskColor = kYellow;
    } else {
      _riskLevel = 'SAFE';
      _riskColor = kGreen;
    }

    // Fuel percent from manual input
    if (!_obd2Connected && _tankCapacity > 0) {
      _fuelPercent = (_fuelLitres / _tankCapacity * 100).clamp(0, 100);
      _animateGauge(_fuelPercent / 100);
      _checkLowFuel();
    }

    setState(() {});
  }

  void _setManualFuel() {
    final l = double.tryParse(_fuelCtrl.text) ?? 0;
    setState(() => _fuelLitres = l);
    _calculate();
  }

  ////////////////////////////////////////////////////////////
  @override
  void dispose() {
    _gaugeController.dispose();
    _posStream?.cancel();
    _obd2Device?.disconnect();
    _searchCtrl.dispose();
    _fuelCtrl.dispose();
    super.dispose();
  }

  ////////////////////////////////////////////////////////////
  // UI
  ////////////////////////////////////////////////////////////
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // ── Dashboard Row ──────────────────
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Fuel gauge
                        _buildFuelGauge(),
                        const SizedBox(width: 12),
                        // Speed + terrain
                        Expanded(child: _buildSpeedCard()),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // ── Vehicle search ────────────────
                    _buildVehicleCard(),

                    const SizedBox(height: 12),

                    // ── Fuel input ────────────────────
                    _buildFuelInputCard(),

                    const SizedBox(height: 12),

                    // ── Range result ──────────────────
                    if (_officialKmpl > 0) _buildRangeCard(),

                    const SizedBox(height: 12),

                    // ── Map ───────────────────────────
                    _buildMapCard(),

                    const SizedBox(height: 12),

                    // ── OBD2 ─────────────────────────
                    _buildOBD2Card(),

                    const SizedBox(height: 12),

                    // ── Nearby stations list ──────────
                    if (_fuelStations.isNotEmpty) _buildStationsList(),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kCard,
        border: Border(bottom: BorderSide(color: kAccent.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_car, color: kAccent, size: 22),
          const SizedBox(width: 8),
          const Text('DRIVER AI',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  letterSpacing: 3)),
          const Spacer(),
          // Online dot
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: _isOnline ? kGreen : Colors.grey,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(_isOnline ? 'LIVE' : 'OFFLINE',
              style: TextStyle(
                  color: _isOnline ? kGreen : Colors.grey,
                  fontSize: 11,
                  letterSpacing: 1)),
          const SizedBox(width: 12),
          // OBD2 badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _obd2Connected
                  ? kGreen.withOpacity(0.15)
                  : Colors.white12,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _obd2Connected ? kGreen : Colors.white24),
            ),
            child: Text('OBD2 ${_obd2Connected ? '✓' : '—'}',
                style: TextStyle(
                    color: _obd2Connected ? kGreen : Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── Circular Fuel Gauge ────────────────────────────────
  Widget _buildFuelGauge() {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          const Text('FUEL', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: _gaugeAnimation,
            builder: (_, __) => CustomPaint(
              size: const Size(110, 110),
              painter: _FuelGaugePainter(_gaugeAnimation.value, _fuelPercent),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_fuelLitres.toStringAsFixed(1)}L',
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16),
          ),
          Text(
            '${_fuelPercent.toStringAsFixed(0)}%',
            style: TextStyle(
                color: _fuelPercent < 20 ? kRed : kAccent,
                fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── Speed + Terrain Card ───────────────────────────────
  Widget _buildSpeedCard() {
    final spd = _obd2Connected ? _obd2Speed : _gpsSpeed;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SPEED', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(spd.toStringAsFixed(0),
                  style: const TextStyle(
                      color: kAccent2,
                      fontSize: 40,
                      fontWeight: FontWeight.w900)),
              const Padding(
                padding: EdgeInsets.only(bottom: 6, left: 4),
                child: Text('km/h',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_terrain.emoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Text(_terrain.label,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Factor: ${(_terrain.factor * 100).toInt()}% • Alt: ${_gpsAlt.toStringAsFixed(0)}m',
            style: const TextStyle(color: Colors.white24, fontSize: 10),
          ),
          if (_obd2Connected) ...[
            const SizedBox(height: 6),
            Text('RPM: ${_obd2Rpm.toStringAsFixed(0)}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  // ── Vehicle Card ───────────────────────────────────────
  Widget _buildVehicleCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('VEHICLE', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search vehicle (Swift, Innova...)',
              hintStyle: const TextStyle(color: Colors.white24),
              prefixIcon: const Icon(Icons.search, color: kAccent, size: 20),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                    )
                  : null,
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kAccent)),
            ),
            onChanged: (v) {
              setState(() => _showSearch = true);
              _searchVehicle(v);
            },
          ),

          // Results dropdown
          if (_showSearch && _searchResults.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kAccent.withOpacity(0.3)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _searchResults.length.clamp(0, 6),
                separatorBuilder: (_, __) =>
                    const Divider(color: Colors.white12, height: 1),
                itemBuilder: (_, i) {
                  final v = _searchResults[i];
                  final brand = v['brand name'] ?? v['brand'] ?? '';
                  final model = v['model name'] ?? v['model'] ?? '';
                  final kmpl  = v['mileage'] ?? v['kmpl'] ?? '?';
                  final fuel  = v['fuel type'] ?? v['fuel'] ?? '';
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.directions_car, color: kAccent, size: 18),
                    title: Text('$brand $model',
                        style: const TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: Text('$kmpl kmpl • $fuel',
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    onTap: () => _selectVehicle(v),
                  );
                },
              ),
            ),

          // Selected vehicle info
          if (_vehicleName.isNotEmpty && !_showSearch) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.check_circle, color: kGreen, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_vehicleName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _chip('${_officialKmpl} kmpl', kAccent),
                const SizedBox(width: 8),
                _chip(_fuelType, _fuelType == 'Diesel' ? kAccent2 : kGreen),
                const SizedBox(width: 8),
                _chip('${_tankCapacity}L tank', Colors.white38),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Fuel Input ─────────────────────────────────────────
  Widget _buildFuelInputCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('FUEL INPUT', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
              const Spacer(),
              if (_obd2Connected)
                _chip('Auto (OBD2)', kGreen)
              else
                _chip('Manual', Colors.white38),
            ],
          ),
          const SizedBox(height: 10),
          if (_obd2Connected)
            Row(
              children: [
                const Icon(Icons.local_gas_station, color: kGreen, size: 20),
                const SizedBox(width: 8),
                Text('${_fuelLitres.toStringAsFixed(1)} L  (${_fuelPercent.toStringAsFixed(0)}%)',
                    style: const TextStyle(
                        color: kGreen,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _fuelCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Enter litres in tank',
                      hintStyle: const TextStyle(color: Colors.white24),
                      suffixText: 'L',
                      suffixStyle: const TextStyle(color: kAccent),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kAccent)),
                    ),
                    onSubmitted: (_) => _setManualFuel(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _setManualFuel,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                  child: const Text(
  'Set',
  style: TextStyle(
    fontWeight: FontWeight.bold,
  ),
),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Range Result Card ──────────────────────────────────
  Widget _buildRangeCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _riskColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _riskColor.withOpacity(0.4), width: 1.5),
        boxShadow: [
          BoxShadow(
              color: _riskColor.withOpacity(0.1),
              blurRadius: 20,
              spreadRadius: 2),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('YOU CAN TRAVEL',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          letterSpacing: 2)),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_range.toStringAsFixed(0),
                          style: TextStyle(
                              color: _riskColor,
                              fontSize: 52,
                              fontWeight: FontWeight.w900,
                              height: 1)),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, left: 6),
                        child: Text('KM',
                            style: TextStyle(
                                color: Colors.white38,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _riskColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _riskColor.withOpacity(0.4)),
                ),
                child: Text(_riskLevel,
                    style: TextStyle(
                        color: _riskColor,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        letterSpacing: 1)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _statTile('Official', '${_officialKmpl} kmpl', Colors.white54),
              _statTile('Adjusted', '${_adjustedKmpl.toStringAsFixed(1)} kmpl', kAccent),
              _statTile('Terrain', '${(_terrain.factor * 100).toInt()}%', kAccent2),
            ],
          ),
        ],
      ),
    );
  }

  // ── Map Card ───────────────────────────────────────────
  Widget _buildMapCard() {
    final center = _userPos ?? const LatLng(13.0827, 80.2707);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('LIVE MAP', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
              const Spacer(),
              GestureDetector(
                onTap: _fetchFuelStations,
                child: const Text('⛽ Refresh Stations',
                    style: TextStyle(color: kAccent, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 280,
              child: FlutterMap(
                mapController: _mapCtrl,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 13,
                ),
                children: [
                  // OSM tiles
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.omnivia.stopsafe',
                  ),

                  // Route polyline
                  if (_routePoints.length > 1)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _routePoints,
                          strokeWidth: 4,
                          color: kAccent2,
                        ),
                      ],
                    ),

                  // Markers
                  MarkerLayer(
                    markers: [
                      // User location
                      if (_userPos != null)
                        Marker(
                          point: _userPos!,
                          width: 40,
                          height: 40,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: kAccent2.withOpacity(0.3),
                              border: Border.all(color: kAccent2, width: 2),
                            ),
                            child: const Icon(Icons.navigation,
                                color: kAccent2, size: 20),
                          ),
                        ),

                      // Fuel station pins
                      ..._fuelStations.map((s) => Marker(
                            point: LatLng(
                                s['lat'] as double, s['lon'] as double),
                            width: 36,
                            height: 36,
                            child: GestureDetector(
                              onTap: () async {
                                final uri = Uri.parse(
                                    'https://www.google.com/maps/dir/?api=1&destination=${s['lat']},${s['lon']}');
                                if (await canLaunchUrl(uri)) launchUrl(uri);
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _fuelPercent < 20
                                      ? kRed.withOpacity(0.9)
                                      : kAccent.withOpacity(0.9),
                                ),
                                child: const Center(
                                  child: Text('⛽',
                                      style: TextStyle(fontSize: 16)),
                                ),
                              ),
                            ),
                          )),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '🔵 You  •  ⛽ Fuel Stations (tap to navigate)  •  — Route',
            style: TextStyle(color: Colors.white24, fontSize: 10),
          ),
        ],
      ),
    );
  }

  // ── OBD2 Card ──────────────────────────────────────────
  Widget _buildOBD2Card() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('OBD2 CONNECT', style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 2)),
              const Spacer(),
              Text(_obd2Status,
                  style: TextStyle(
                      color: _obd2Connected ? kGreen : Colors.white38,
                      fontSize: 11)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _scanBT,
                  icon: const Icon(Icons.bluetooth_searching, size: 16),
                  label: const Text('Scan Devices'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withOpacity(0.05),
                    foregroundColor: kAccent,
                    side: const BorderSide(color: kAccent),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              if (_obd2Connected) ...[
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _disconnectOBD2,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kRed.withOpacity(0.15),
                    foregroundColor: kRed,
                    side: const BorderSide(color: kRed),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Disconnect'),
                ),
              ],
            ],
          ),
          if (_btDevices.isNotEmpty) ...[
            const SizedBox(height: 10),
            ..._btDevices.map((d) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bluetooth, color: kAccent, size: 18),
                  title: Text(d.platformName,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                  trailing: TextButton(
                    onPressed: () => _connectOBD2(d),
                    child: const Text('Connect',
                        style: TextStyle(color: kAccent)),
                  ),
                )),
          ],
          if (_obd2Connected) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statTile('Fuel', '${_fuelPercent.toStringAsFixed(0)}%', kGreen),
                _statTile('Speed', '${_obd2Speed.toStringAsFixed(0)} km/h', kAccent2),
                _statTile('RPM', _obd2Rpm.toStringAsFixed(0), kAccent),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Fuel Stations List ─────────────────────────────────
  Widget _buildStationsList() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('NEARBY FUEL STATIONS',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 10),
          ..._fuelStations.take(4).map((s) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: kAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                      child: Text('⛽', style: TextStyle(fontSize: 16))),
                ),
                title: Text(s['name'],
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: Text(s['brand'] ?? '',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${(s['dist'] as double).toStringAsFixed(1)} km',
                      style: const TextStyle(
                          color: kAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                    const Text('tap to go',
                        style:
                            TextStyle(color: Colors.white24, fontSize: 10)),
                  ],
                ),
                onTap: () async {
                  final uri = Uri.parse(
                      'https://www.google.com/maps/dir/?api=1&destination=${s['lat']},${s['lon']}');
                  if (await canLaunchUrl(uri)) launchUrl(uri);
                },
              )),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────
  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }

  Widget _statTile(String label, String value, Color color) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    );
  }
}

////////////////////////////////////////////////////////////
/// CIRCULAR FUEL GAUGE PAINTER
/// Car dashboard style — arc + needle + glow
////////////////////////////////////////////////////////////
class _FuelGaugePainter extends CustomPainter {
  final double value; // 0.0 to 1.0 (animated)
  final double percent;

  _FuelGaugePainter(this.value, this.percent);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = size.width * 0.42;

    // Arc range: 225° to -45° (270° sweep, bottom open)
    const startAngle = 2.356; // 135° in radians (bottom-left)
    const sweepAngle = 5.236; // 300° sweep

    // ── Background arc ──────────────────────────────────
    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = Colors.white12;

    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      startAngle,
      sweepAngle,
      false,
      bgPaint,
    );

    // ── Colored fuel arc ────────────────────────────────
    final fuelColor = value < 0.2
        ? kRed
        : value < 0.4
            ? kYellow
            : kGreen;

    final fuelPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [fuelColor.withOpacity(0.5), fuelColor],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: radius));

    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      startAngle,
      sweepAngle * value,
      false,
      fuelPaint,
    );

    // ── Glow on tip ──────────────────────────────────────
    if (value > 0.01) {
      final tipAngle = startAngle + sweepAngle * value;
      final tipX = cx + radius * cos(tipAngle);
      final tipY = cy + radius * sin(tipAngle);

      final glowPaint = Paint()
        ..color = fuelColor.withOpacity(0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(Offset(tipX, tipY), 8, glowPaint);

      final dotPaint = Paint()..color = fuelColor;
      canvas.drawCircle(Offset(tipX, tipY), 5, dotPaint);
    }

    // ── E / F labels ─────────────────────────────────────
    const labelStyle = TextStyle(color: Colors.white38, fontSize: 10);

    // E label (empty side)
    _drawText(canvas, 'E', Offset(cx - radius + 2, cy + 16), labelStyle);
    // F label (full side)
    _drawText(canvas, 'F', Offset(cx + radius - 12, cy + 16), labelStyle);

    // ── Center percent text ───────────────────────────────
    _drawText(
      canvas,
      '${percent.toStringAsFixed(0)}%',
      Offset(cx - 14, cy - 8),
      TextStyle(
          color: fuelColor,
          fontSize: 18,
          fontWeight: FontWeight.w900),
    );
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_FuelGaugePainter old) =>
      old.value != value || old.percent != percent;
}