import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

////////////////////////////////////////////////////////////
/// HIGHWAY OFFLINE PACK
/// Online  → Overpass API (OpenStreetMap real data)
/// Offline → SQLite preloaded TN highway data
/// Map     → flutter_map + OSM tiles
////////////////////////////////////////////////////////////

// ── Data Model ────────────────────────────────────────────
class EmergencyPoint {
  final String category;
  final String name;
  final String address;
  final String phone;
  final double latitude;
  final double longitude;
  double distanceKm;

  EmergencyPoint({
    required this.category,
    required this.name,
    required this.address,
    required this.phone,
    required this.latitude,
    required this.longitude,
    this.distanceKm = 0,
  });

  Map<String, dynamic> toMap() => {
        'category': category,
        'name': name,
        'address': address,
        'phone': phone,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory EmergencyPoint.fromMap(Map<String, dynamic> m) => EmergencyPoint(
        category: m['category'] ?? '',
        name: m['name'] ?? '',
        address: m['address'] ?? '',
        phone: m['phone'] ?? '',
        latitude: (m['latitude'] as num).toDouble(),
        longitude: (m['longitude'] as num).toDouble(),
      );
}

// ── Category Config ───────────────────────────────────────
class CategoryConfig {
  final String emoji;
  final String label;
  final String overpassTag;
  final Color color;

  const CategoryConfig({
    required this.emoji,
    required this.label,
    required this.overpassTag,
    required this.color,
  });
}

const Map<String, CategoryConfig> kCategories = {
  'fuel': CategoryConfig(
    emoji: '⛽',
    label: 'Fuel Station',
    overpassTag: 'amenity=fuel',
    color: Color(0xFFFF9800),
  ),
  'hospital': CategoryConfig(
    emoji: '🏥',
    label: 'Hospital',
    overpassTag: 'amenity=hospital',
    color: Color(0xFFF44336),
  ),
  'police': CategoryConfig(
    emoji: '🚔',
    label: 'Police',
    overpassTag: 'amenity=police',
    color: Color(0xFF2196F3),
  ),
  'mechanic': CategoryConfig(
    emoji: '🔧',
    label: 'Mechanic',
    overpassTag: 'shop=car_repair',
    color: Color(0xFF9C27B0),
  ),
  'restaurant': CategoryConfig(
    emoji: '🍽️',
    label: 'Restaurant',
    overpassTag: 'amenity=restaurant',
    color: Color(0xFF4CAF50),
  ),
  'atm': CategoryConfig(
    emoji: '🏧',
    label: 'ATM',
    overpassTag: 'amenity=atm',
    color: Color(0xFF00BCD4),
  ),
  'hotel': CategoryConfig(
    emoji: '🛏️',
    label: 'Hotel',
    overpassTag: 'tourism=hotel',
    color: Color(0xFFE91E63),
  ),
};

// ── SQLite Helper ─────────────────────────────────────────
class HighwayDatabase {
  static Database? _db;

  static Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'highway.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category TEXT,
            name TEXT,
            address TEXT,
            phone TEXT,
            latitude REAL,
            longitude REAL
          )
        ''');
        await _seedTNData(db);
      },
    );
  }

  // ── Preloaded TN Highway Data ────────────────────────────
  static Future<void> _seedTNData(Database db) async {
    final List<EmergencyPoint> tnPoints = [
      // ── NH44 (Chennai - Krishnagiri) ─────────────────────
      EmergencyPoint(category: 'fuel', name: 'Indian Oil - Ambattur', address: 'NH44, Ambattur, Chennai', phone: '9444100001', latitude: 13.114, longitude: 80.155),
      EmergencyPoint(category: 'fuel', name: 'HP Petrol Pump - Veppampattu', address: 'NH44, Veppampattu', phone: '9444100002', latitude: 13.200, longitude: 79.970),
      EmergencyPoint(category: 'fuel', name: 'BPCL - Ranipet', address: 'NH44, Ranipet', phone: '9444100003', latitude: 12.924, longitude: 79.332),
      EmergencyPoint(category: 'hospital', name: 'Govt Hospital - Vellore', address: 'NH44, Vellore', phone: '0416-2225000', latitude: 12.916, longitude: 79.132),
      EmergencyPoint(category: 'hospital', name: 'Apollo First Med - Ambattur', address: 'NH44, Ambattur', phone: '044-42244224', latitude: 13.098, longitude: 80.165),
      EmergencyPoint(category: 'police', name: 'Highway Patrol - Sriperumbudur', address: 'NH44, Sriperumbudur', phone: '100', latitude: 12.967, longitude: 79.948),
      EmergencyPoint(category: 'police', name: 'Ranipet Police Station', address: 'NH44, Ranipet', phone: '100', latitude: 12.922, longitude: 79.335),
      EmergencyPoint(category: 'mechanic', name: 'Highway Auto Service - Ambattur', address: 'NH44, Ambattur', phone: '9876500001', latitude: 13.110, longitude: 80.158),
      EmergencyPoint(category: 'restaurant', name: 'Saravana Bhavan - NH44', address: 'NH44, Kanchipuram Bypass', phone: '9876500010', latitude: 12.840, longitude: 79.705),
      EmergencyPoint(category: 'atm', name: 'SBI ATM - Ranipet', address: 'NH44, Ranipet', phone: '', latitude: 12.920, longitude: 79.330),
      EmergencyPoint(category: 'hotel', name: 'Hotel Highway Residency', address: 'NH44, Vellore Bypass', phone: '9444200001', latitude: 12.910, longitude: 79.140),

      // ── NH45 (Chennai - Trichy) ───────────────────────────
      EmergencyPoint(category: 'fuel', name: 'Indian Oil - Tambaram', address: 'NH45, Tambaram', phone: '9444300001', latitude: 12.924, longitude: 80.127),
      EmergencyPoint(category: 'fuel', name: 'HP - Chengalpattu', address: 'NH45, Chengalpattu', phone: '9444300002', latitude: 12.692, longitude: 79.975),
      EmergencyPoint(category: 'fuel', name: 'BPCL - Melmaruvathur', address: 'NH45, Melmaruvathur', phone: '9444300003', latitude: 12.557, longitude: 79.884),
      EmergencyPoint(category: 'fuel', name: 'Indian Oil - Villupuram', address: 'NH45, Villupuram', phone: '9444300004', latitude: 11.939, longitude: 79.492),
      EmergencyPoint(category: 'hospital', name: 'Govt Hospital - Chengalpattu', address: 'NH45, Chengalpattu', phone: '044-27427100', latitude: 12.695, longitude: 79.980),
      EmergencyPoint(category: 'hospital', name: 'Govt Hospital - Villupuram', address: 'NH45, Villupuram', phone: '04146-220333', latitude: 11.936, longitude: 79.494),
      EmergencyPoint(category: 'police', name: 'Highway Police - Chengalpattu', address: 'NH45, Chengalpattu Toll', phone: '100', latitude: 12.690, longitude: 79.972),
      EmergencyPoint(category: 'police', name: 'Melmaruvathur Police', address: 'NH45, Melmaruvathur', phone: '100', latitude: 12.555, longitude: 79.882),
      EmergencyPoint(category: 'mechanic', name: 'Auto Care - Tambaram', address: 'NH45, Tambaram Bypass', phone: '9876500020', latitude: 12.920, longitude: 80.122),
      EmergencyPoint(category: 'restaurant', name: 'Anjappar - Chengalpattu', address: 'NH45, Chengalpattu', phone: '9876500030', latitude: 12.688, longitude: 79.978),
      EmergencyPoint(category: 'atm', name: 'Canara ATM - Villupuram', address: 'NH45, Villupuram', phone: '', latitude: 11.937, longitude: 79.490),
      EmergencyPoint(category: 'hotel', name: 'Hotel Melmar Residency', address: 'NH45, Melmaruvathur', phone: '9444400001', latitude: 12.554, longitude: 79.880),

      // ── NH48 (Chennai - Bangalore) ────────────────────────
      EmergencyPoint(category: 'fuel', name: 'Indian Oil - Poonamallee', address: 'NH48, Poonamallee', phone: '9444500001', latitude: 13.047, longitude: 80.096),
      EmergencyPoint(category: 'fuel', name: 'HP - Sriperumbudur', address: 'NH48, Sriperumbudur', phone: '9444500002', latitude: 12.968, longitude: 79.945),
      EmergencyPoint(category: 'fuel', name: 'BPCL - Kanchipuram', address: 'NH48, Kanchipuram', phone: '9444500003', latitude: 12.836, longitude: 79.705),
      EmergencyPoint(category: 'hospital', name: 'Govt Hospital - Kanchipuram', address: 'NH48, Kanchipuram', phone: '044-27222206', latitude: 12.838, longitude: 79.702),
      EmergencyPoint(category: 'police', name: 'Highway Patrol - Poonamallee', address: 'NH48, Poonamallee Toll', phone: '100', latitude: 13.042, longitude: 80.090),
      EmergencyPoint(category: 'mechanic', name: 'Speed Auto - Sriperumbudur', address: 'NH48, Sriperumbudur', phone: '9876500040', latitude: 12.965, longitude: 79.942),
      EmergencyPoint(category: 'restaurant', name: 'Vasantha Bhavan - Kanchipuram', address: 'NH48, Kanchipuram', phone: '9876500050', latitude: 12.834, longitude: 79.707),
      EmergencyPoint(category: 'atm', name: 'HDFC ATM - Sriperumbudur', address: 'NH48, Sriperumbudur', phone: '', latitude: 12.966, longitude: 79.947),
      EmergencyPoint(category: 'hotel', name: 'Radha Residency - Kanchipuram', address: 'NH48, Kanchipuram', phone: '9444600001', latitude: 12.832, longitude: 79.700),

      // ── NH181 (Coimbatore - Salem) ────────────────────────
      EmergencyPoint(category: 'fuel', name: 'Indian Oil - Erode Bypass', address: 'NH181, Erode', phone: '9444700001', latitude: 11.341, longitude: 77.728),
      EmergencyPoint(category: 'hospital', name: 'Govt Hospital - Erode', address: 'NH181, Erode', phone: '0424-2256811', latitude: 11.344, longitude: 77.726),
      EmergencyPoint(category: 'police', name: 'Highway Police - Erode', address: 'NH181, Erode Toll', phone: '100', latitude: 11.339, longitude: 77.730),
      EmergencyPoint(category: 'mechanic', name: 'Raja Auto - Erode', address: 'NH181, Erode', phone: '9876500060', latitude: 11.342, longitude: 77.725),
      EmergencyPoint(category: 'restaurant', name: 'Hotel Sri Balaji - Erode', address: 'NH181, Erode', phone: '9876500070', latitude: 11.340, longitude: 77.727),
      EmergencyPoint(category: 'atm', name: 'IOB ATM - Erode', address: 'NH181, Erode', phone: '', latitude: 11.343, longitude: 77.729),
      EmergencyPoint(category: 'hotel', name: 'Hotel Erode Residency', address: 'NH181, Erode', phone: '9444800001', latitude: 11.338, longitude: 77.724),

      // ── NH83 (Trichy - Madurai) ───────────────────────────
      EmergencyPoint(category: 'fuel', name: 'HP - Dindigul Bypass', address: 'NH83, Dindigul', phone: '9444900001', latitude: 10.365, longitude: 77.975),
      EmergencyPoint(category: 'hospital', name: 'Govt Hospital - Dindigul', address: 'NH83, Dindigul', phone: '0451-2422201', latitude: 10.368, longitude: 77.972),
      EmergencyPoint(category: 'police', name: 'Highway Police - Dindigul', address: 'NH83, Dindigul', phone: '100', latitude: 10.363, longitude: 77.977),
      EmergencyPoint(category: 'mechanic', name: 'Murugan Auto - Dindigul', address: 'NH83, Dindigul', phone: '9876500080', latitude: 10.366, longitude: 77.974),
      EmergencyPoint(category: 'restaurant', name: 'Pandian Hotel - Dindigul', address: 'NH83, Dindigul', phone: '9876500090', latitude: 10.364, longitude: 77.976),
      EmergencyPoint(category: 'atm', name: 'SBI ATM - Dindigul', address: 'NH83, Dindigul', phone: '', latitude: 10.367, longitude: 77.973),
      EmergencyPoint(category: 'hotel', name: 'Hotel Dindigul Towers', address: 'NH83, Dindigul', phone: '9445000001', latitude: 10.362, longitude: 77.978),
    ];

    final batch = db.batch();
    for (final pt in tnPoints) {
      batch.insert('points', pt.toMap());
    }
    await batch.commit(noResult: true);
  }

  static Future<List<EmergencyPoint>> getNearby(
      double lat, double lon, String category, double radiusKm) async {
    final database = await db;
    final results = await database.query(
      'points',
      where: 'category = ?',
      whereArgs: [category],
    );
    final points = results.map((m) => EmergencyPoint.fromMap(m)).toList();

    // Filter by radius + sort by distance
    final filtered = points.where((pt) {
      final d = _haversine(lat, lon, pt.latitude, pt.longitude);
      pt.distanceKm = d;
      return d <= radiusKm;
    }).toList();

    filtered.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return filtered;
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) *
            cos(_deg2rad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _deg2rad(double deg) => deg * pi / 180;
}

// ── Overpass API Service ──────────────────────────────────
class OverpassService {
  static const String _url = 'https://overpass-api.de/api/interpreter';

  static Future<List<EmergencyPoint>> fetchNearby({
    required double lat,
    required double lon,
    required String category,
    double radiusMeters = 15000,
  }) async {
    final cfg = kCategories[category]!;
    final tag = cfg.overpassTag.split('=');
    final query = '''
[out:json][timeout:25];
(
  node["${tag[0]}"="${tag[1]}"](around:$radiusMeters,$lat,$lon);
  way["${tag[0]}"="${tag[1]}"](around:$radiusMeters,$lat,$lon);
);
out center 10;
''';

    try {
      final res = await http
          .post(Uri.parse(_url), body: query)
          .timeout(const Duration(seconds: 20));

      if (res.statusCode != 200) return [];

      final data = jsonDecode(res.body);
      final elements = data['elements'] as List;
      final List<EmergencyPoint> points = [];

      for (final el in elements) {
        final tags = el['tags'] ?? {};
        final elLat = (el['lat'] ?? el['center']?['lat'] ?? 0.0) as double;
        final elLon = (el['lon'] ?? el['center']?['lon'] ?? 0.0) as double;
        if (elLat == 0.0) continue;

        final name = tags['name'] ?? tags['operator'] ?? cfg.label;
        final phone = tags['phone'] ??
            tags['contact:phone'] ??
            tags['contact:mobile'] ??
            '';
        final address = [
          tags['addr:housenumber'],
          tags['addr:street'],
          tags['addr:city'],
        ].where((e) => e != null).join(', ');

        final dist = HighwayDatabase._haversine(lat, lon, elLat, elLon);
        points.add(EmergencyPoint(
          category: category,
          name: name,
          address: address.isNotEmpty ? address : 'Near your location',
          phone: phone,
          latitude: elLat,
          longitude: elLon,
          distanceKm: dist,
        ));
      }

      points.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
      return points.take(5).toList();
    } catch (_) {
      return [];
    }
  }
}

////////////////////////////////////////////////////////////
/// MAIN PAGE
////////////////////////////////////////////////////////////
class HighwayPage extends StatefulWidget {
  const HighwayPage({super.key});

  @override
  State<HighwayPage> createState() => _HighwayPageState();
}

class _HighwayPageState extends State<HighwayPage> {
  Position? _userPosition;
  String _selectedCategory = 'fuel';
  List<EmergencyPoint> _points = [];
  bool _loading = false;
  bool _isOnline = false;
  String _dataSource = '';
  EmergencyPoint? _selectedPoint;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _checkConnectivity();
    await _getLocation();
    await _loadData();
  }

  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    setState(() {
      _isOnline = result != ConnectivityResult.none;
    });
  }

  Future<void> _getLocation() async {
    try {
      LocationPermission perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) return;
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      setState(() => _userPosition = pos);
    } catch (_) {}
  }

  Future<void> _loadData() async {
    if (_userPosition == null) return;
    setState(() {
      _loading = true;
      _points = [];
      _selectedPoint = null;
    });

    final lat = _userPosition!.latitude;
    final lon = _userPosition!.longitude;

    List<EmergencyPoint> results = [];

    if (_isOnline) {
      // Try Overpass API first
      results = await OverpassService.fetchNearby(
        lat: lat,
        lon: lon,
        category: _selectedCategory,
      );
      _dataSource = '🌐 Live OSM Data';
    }

    // Fallback to SQLite if online failed or offline
    if (results.isEmpty) {
      results = await HighwayDatabase.getNearby(lat, lon, _selectedCategory, 100);
      _dataSource = '📦 Offline Database';
    }

    setState(() {
      _points = results;
      _loading = false;
    });

    // Move map to user location
    if (_userPosition != null) {
      _mapController.move(
        LatLng(_userPosition!.latitude, _userPosition!.longitude),
        11,
      );
    }
  }

  Future<void> _makeCall(String phone) async {
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone number available')),
      );
      return;
    }
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _openMap(double lat, double lon, String name) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.directions_car, color: Color(0xFFFF9800), size: 22),
            SizedBox(width: 8),
            Text(
              'Highway Pack',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: (_isOnline ? Colors.green : Colors.orange).withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: _isOnline ? Colors.green : Colors.orange, width: 1),
              ),
              child: Row(
                children: [
                  Icon(
                    _isOnline ? Icons.wifi : Icons.wifi_off,
                    color: _isOnline ? Colors.green : Colors.orange,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isOnline ? 'Online' : 'Offline',
                    style: TextStyle(
                        color: _isOnline ? Colors.green : Colors.orange,
                        fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Category Selector ──────────────────────────
          _buildCategorySelector(),

          // ── Map ───────────────────────────────────────
          _buildMap(),

          // ── Data Source Label ─────────────────────────
          if (_dataSource.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text(_dataSource,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                  const Spacer(),
                  Text('${_points.length} results',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),

          // ── Results List ──────────────────────────────
          Expanded(child: _buildResultsList()),
        ],
      ),
    );
  }

  // ── Category Selector ─────────────────────────────────
  Widget _buildCategorySelector() {
    return SizedBox(
      height: 70,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        children: kCategories.entries.map((entry) {
          final selected = entry.key == _selectedCategory;
          final cfg = entry.value;
          return GestureDetector(
            onTap: () async {
              setState(() => _selectedCategory = entry.key);
              await _loadData();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? cfg.color.withOpacity(0.25)
                    : const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? cfg.color : Colors.white12,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Text(cfg.emoji, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 6),
                  Text(
                    cfg.label,
                    style: TextStyle(
                      color: selected ? cfg.color : Colors.white54,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Map ───────────────────────────────────────────────
  Widget _buildMap() {
    final userLat = _userPosition?.latitude ?? 13.0827;
    final userLon = _userPosition?.longitude ?? 80.2707;
    final cfg = kCategories[_selectedCategory]!;

    return Container(
      height: 220,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.hardEdge,
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: LatLng(userLat, userLon),
          initialZoom: 11,
          onTap: (_, __) => setState(() => _selectedPoint = null),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.omnivia.stopsafe',
          ),
          MarkerLayer(
            markers: [
              // User marker
              Marker(
                point: LatLng(userLat, userLon),
                width: 40,
                height: 40,
                child: const Icon(Icons.my_location,
                    color: Colors.blue, size: 30),
              ),
              // POI markers
              ..._points.map((pt) => Marker(
                    point: LatLng(pt.latitude, pt.longitude),
                    width: 40,
                    height: 40,
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedPoint = pt),
                      child: Column(
                        children: [
                          Text(cfg.emoji,
                              style: const TextStyle(fontSize: 20)),
                        ],
                      ),
                    ),
                  )),
            ],
          ),
          // Selected popup
          if (_selectedPoint != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: LatLng(
                      _selectedPoint!.latitude, _selectedPoint!.longitude),
                  width: 200,
                  height: 80,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: cfg.color),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedPoint!.name,
                          style: TextStyle(
                              color: cfg.color,
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_selectedPoint!.distanceKm.toStringAsFixed(1)} KM away',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Results List ──────────────────────────────────────
  Widget _buildResultsList() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF9800)),
            SizedBox(height: 12),
            Text('Searching nearby...',
                style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    if (_userPosition == null) {
      return const Center(
        child: Text('📍 Enable location to find nearby places',
            style: TextStyle(color: Colors.white54)),
      );
    }

    if (_points.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(kCategories[_selectedCategory]!.emoji,
                style: const TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            const Text('No results found nearby',
                style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadData,
              child: const Text('Retry',
                  style: TextStyle(color: Color(0xFFFF9800))),
            ),
          ],
        ),
      );
    }

    final cfg = kCategories[_selectedCategory]!;

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _points.length,
      itemBuilder: (context, index) {
        final pt = _points[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _selectedPoint == pt
                  ? cfg.color
                  : Colors.white12,
              width: _selectedPoint == pt ? 1.5 : 1,
            ),
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            onTap: () {
              setState(() => _selectedPoint = pt);
              _mapController.move(
                  LatLng(pt.latitude, pt.longitude), 14);
            },
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cfg.color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child:
                    Text(cfg.emoji, style: const TextStyle(fontSize: 22)),
              ),
            ),
            title: Text(
              pt.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(pt.address,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.location_on,
                        color: cfg.color, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      '${pt.distanceKm.toStringAsFixed(1)} KM away',
                      style: TextStyle(
                          color: cfg.color,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                GestureDetector(
                  onTap: () => _makeCall(pt.phone),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.call,
                        color: Colors.green, size: 18),
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () =>
                      _openMap(pt.latitude, pt.longitude, pt.name),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.directions,
                        color: Colors.blue, size: 18),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}