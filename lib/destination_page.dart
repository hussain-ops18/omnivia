import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

////////////////////////////////////////////////////////////
/// OMNIVIA DESTINATION ALARM
/// • OSRM routing (FREE — no API key!)
/// • Nominatim geocoding (FREE — no API key!)
/// • Real distance + ETA
/// • Traffic simulation (time-based)
/// • Alarm on arrival
/// • Dark HUD UI
////////////////////////////////////////////////////////////

// ── Colors ────────────────────────────────────────────────
const kBg      = Color(0xFF0A0A0F);
const kCard    = Color(0xFF12121A);
const kAccent  = Color(0xFF6C63FF);
const kGreen   = Color(0xFF00FF88);
const kRed     = Color(0xFFFF3355);
const kYellow  = Color(0xFFFFD600);
const kCyan    = Color(0xFF00D4FF);

////////////////////////////////////////////////////////////
/// OSRM Routing Service (FREE — no API key needed!)
////////////////////////////////////////////////////////////
class OSRMService {
  static const _base = 'https://router.project-osrm.org/route/v1/driving';

  static Future<Map<String, dynamic>?> getRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
  }) async {
    try {
      final url = Uri.parse(
        '$_base/$startLng,$startLat;$endLng,$endLat'
        '?overview=false&steps=false',
      );
      final res = await http.get(url, headers: {
        'User-Agent': 'OmniviaApp/1.0',
      }).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['code'] == 'Ok' && data['routes'] != null && data['routes'].isNotEmpty) {
          return data['routes'][0];
        }
      }
    } catch (_) {}
    return null;
  }
}

////////////////////////////////////////////////////////////
/// Nominatim Geocoding (FREE — no API key needed!)
////////////////////////////////////////////////////////////
class NominatimService {
  static const _base = 'https://nominatim.openstreetmap.org';

  static Future<Map<String, dynamic>?> search(String query) async {
    try {
      final url = Uri.parse(
        '$_base/search?q=${Uri.encodeComponent(query)}'
        '&format=json&limit=5&addressdetails=1',
      );
      final res = await http.get(url, headers: {
        'User-Agent': 'OmniviaApp/1.0',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        if (data.isNotEmpty) return data.first as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> suggestions(String query) async {
    if (query.length < 3) return [];
    try {
      final url = Uri.parse(
        '$_base/search?q=${Uri.encodeComponent(query)}'
        '&format=json&limit=5&addressdetails=0',
      );
      final res = await http.get(url, headers: {
        'User-Agent': 'OmniviaApp/1.0',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        return data.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }
}

////////////////////////////////////////////////////////////
/// DESTINATION PAGE
////////////////////////////////////////////////////////////
class DestinationPage extends StatefulWidget {
  const DestinationPage({super.key});

  @override
  State<DestinationPage> createState() => _DestinationPageState();
}

class _DestinationPageState extends State<DestinationPage>
    with TickerProviderStateMixin {

  // ── Controllers ───────────────────────────────────────
  final _searchCtrl = TextEditingController();
  final _player     = AudioPlayer();
  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  // ── State ─────────────────────────────────────────────
  Timer?   _journeyTimer;
  bool     _running        = false;
  bool     _alarmTriggered = false;
  bool     _searching      = false;
  String   _status         = '📍 Ready — Search your destination';
  String   _trafficStatus  = 'Waiting for route...';
  Color    _trafficColor   = Colors.white38;

  // ── Location ──────────────────────────────────────────
  Position? _currentPos;
  double    _destLat       = 0;
  double    _destLng       = 0;
  String    _destName      = '';

  // ── Journey metrics ───────────────────────────────────
  double _remainingM       = 0;
  double _totalM           = 0;
  double _progress         = 0;
  double _speedKmh         = 0;
  double _etaMinutes       = 0;
  int    _trafficDelaySec  = 0;
  double _osrmDistanceM    = 0;
  double _osrmDurationSec  = 0;

  // ── Suggestions ───────────────────────────────────────
  List<Map<String, dynamic>> _suggestions = [];
  bool _showSuggestions = false;
  Timer? _debounce;

  ////////////////////////////////////////////////////////////
  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _getLocation();
  }

  ////////////////////////////////////////////////////////////
  // GET LOCATION
  ////////////////////////////////////////////////////////////
  Future<void> _getLocation() async {
    try {
      bool enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        _setStatus('⚠️ Enable location services');
        return;
      }
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        _setStatus('❌ Location permission denied');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      setState(() {
        _currentPos = pos;
        _status     = '📍 Location ready — Search destination';
      });
    } catch (e) {
      _setStatus('❌ Location error — retry');
    }
  }

  ////////////////////////////////////////////////////////////
  // SEARCH DESTINATION
  ////////////////////////////////////////////////////////////
  Future<void> _searchDestination(String query) async {
    if (query.length < 3) {
      setState(() => _suggestions = []);
      return;
    }

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final results = await NominatimService.suggestions(query);
      if (mounted) {
        setState(() {
          _suggestions    = results;
          _showSuggestions = results.isNotEmpty;
        });
      }
    });
  }

  Future<void> _selectDestination(Map<String, dynamic> place) async {
    final lat  = double.tryParse(place['lat'].toString()) ?? 0;
    final lon  = double.tryParse(place['lon'].toString()) ?? 0;
    final name = place['display_name']?.toString().split(',').take(2).join(', ') ?? '';

    setState(() {
      _destLat         = lat;
      _destLng         = lon;
      _destName        = name;
      _showSuggestions = false;
      _searchCtrl.text = name;
      _suggestions     = [];
    });

    _setStatus('🔍 Calculating route...');
    await _fetchRoute();
  }

  ////////////////////////////////////////////////////////////
  // FETCH ROUTE — OSRM
  ////////////////////////////////////////////////////////////
  Future<void> _fetchRoute() async {
    if (_currentPos == null || _destLat == 0) return;

    setState(() => _searching = true);

    final route = await OSRMService.getRoute(
      startLat: _currentPos!.latitude,
      startLng: _currentPos!.longitude,
      endLat:   _destLat,
      endLng:   _destLng,
    );

    setState(() => _searching = false);

    if (route == null) {
      _setStatus('❌ Route not found — check internet');
      return;
    }

    final distM   = (route['distance'] as num).toDouble();
    final durSec  = (route['duration'] as num).toDouble();

    // Traffic simulation
    final hour = DateTime.now().hour;
    int delaySec;
    String tStatus;
    Color tColor;

    if (hour >= 8 && hour <= 10) {
      delaySec = (durSec * 0.35).toInt();
      tStatus  = '🔴 Heavy Traffic — Morning peak +${(delaySec / 60).toInt()} min';
      tColor   = kRed;
    } else if (hour >= 17 && hour <= 20) {
      delaySec = (durSec * 0.40).toInt();
      tStatus  = '🔴 Heavy Traffic — Evening peak +${(delaySec / 60).toInt()} min';
      tColor   = kRed;
    } else if (hour >= 12 && hour <= 14) {
      delaySec = (durSec * 0.15).toInt();
      tStatus  = '🟡 Moderate Traffic +${(delaySec / 60).toInt()} min';
      tColor   = kYellow;
    } else {
      delaySec = (durSec * 0.05).toInt();
      tStatus  = '🟢 Light Traffic — Clear roads';
      tColor   = kGreen;
    }

    final totalSec = durSec + delaySec;

    setState(() {
      _osrmDistanceM   = distM;
      _osrmDurationSec = totalSec;
      _remainingM      = distM;
      _totalM          = distM;
      _trafficDelaySec = delaySec;
      _trafficStatus   = tStatus;
      _trafficColor    = tColor;
      _etaMinutes      = totalSec / 60;
    });

    _setStatus(
      '✅ ${(distM / 1000).toStringAsFixed(1)} km  •  ${(totalSec / 60).toInt()} min',
    );
  }

  ////////////////////////////////////////////////////////////
  // START / STOP JOURNEY
  ////////////////////////////////////////////////////////////
  void _startJourney() {
    if (_destLat == 0) {
      _setStatus('⚠️ Set destination first!');
      return;
    }
    if (_currentPos == null) {
      _setStatus('⚠️ Location not ready');
      return;
    }

    setState(() {
      _running        = true;
      _alarmTriggered = false;
    });

    _journeyTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      await _updateJourney();
    });
  }

  void _stopJourney() async {
    await _player.stop();
    _journeyTimer?.cancel();
    setState(() {
      _running        = false;
      _alarmTriggered = false;
      _progress       = 0;
      _speedKmh       = 0;
      _etaMinutes     = _osrmDurationSec / 60;
      _remainingM     = _osrmDistanceM;
    });
    _setStatus('📍 Journey stopped');
  }

  Future<void> _updateJourney() async {
    if (!_running) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);

      final remainM = _haversine(
        pos.latitude, pos.longitude, _destLat, _destLng,
      );

      final spd = (pos.speed * 3.6).clamp(0.0, 200.0);
      double eta = _etaMinutes;
      if (spd > 2) eta = (remainM / 1000) / spd * 60;

      setState(() {
        _currentPos = pos;
        _remainingM = remainM;
        _speedKmh   = spd;
        _etaMinutes = eta;
        _progress   = _totalM > 0
            ? (1 - remainM / _totalM).clamp(0.0, 1.0)
            : 0;
      });

      _updateStatus();
      _checkAlarm(remainM);
    } catch (_) {}
  }

  void _checkAlarm(double remainM) {
    if (_alarmTriggered) return;
    // Alert when < 200m or ETA < 30 sec
    if (remainM <= 200 || (_speedKmh > 2 && _etaMinutes <= 0.5)) {
      _alarmTriggered = true;
      _triggerAlarm();
    }
  }

  void _updateStatus() {
    if (_remainingM <= 200) {
      _setStatus('🎯 Almost there!');
    } else if (_speedKmh > 2) {
      _setStatus(
          '🚗 ${_etaMinutes.toInt()} min  •  ${(_remainingM / 1000).toStringAsFixed(1)} km  •  ${_speedKmh.toInt()} km/h');
    } else {
      _setStatus('📍 ${(_remainingM / 1000).toStringAsFixed(1)} km remaining');
    }
  }

  Future<void> _triggerAlarm() async {
    HapticFeedback.heavyImpact();
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('alarm.mp3'));
    } catch (_) {}

    if (!mounted) return;
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (_) => _buildAlarmDialog(),
    );
  }

  ////////////////////////////////////////////////////////////
  // HELPERS
  ////////////////////////////////////////////////////////////
  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _rad(double deg) => deg * pi / 180;

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _player.dispose();
    _journeyTimer?.cancel();
    _debounce?.cancel();
    _searchCtrl.dispose();
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
              child: GestureDetector(
                onTap: () => setState(() => _showSuggestions = false),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildSearchCard(),
                      const SizedBox(height: 12),
                      if (_destName.isNotEmpty) _buildDestCard(),
                      const SizedBox(height: 12),
                      if (_destName.isNotEmpty) _buildTrafficCard(),
                      const SizedBox(height: 12),
                      _buildStatusCard(),
                      const SizedBox(height: 12),
                      if (_running || _progress > 0) _buildProgressCard(),
                      const SizedBox(height: 12),
                      _buildStartStopButton(),
                      const SizedBox(height: 20),
                    ],
                  ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0F0F1A), Color(0xFF1A1030)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border(
            bottom: BorderSide(color: kAccent.withOpacity(0.4), width: 1.5)),
        boxShadow: [
          BoxShadow(
              color: kAccent.withOpacity(0.15),
              blurRadius: 20,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: kAccent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kAccent.withOpacity(0.4)),
            ),
            child: const Icon(Icons.location_on, color: kAccent, size: 20),
          ),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OMNIVIA',
                  style: TextStyle(
                      color: kAccent,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      letterSpacing: 4)),
              Text('DESTINATION ALARM',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w300,
                      fontSize: 10,
                      letterSpacing: 3)),
            ],
          ),
          const Spacer(),
          if (_running)
            ScaleTransition(
              scale: _pulseAnim,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: kGreen.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kGreen),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.circle, color: kGreen, size: 8),
                    SizedBox(width: 4),
                    Text('ACTIVE',
                        style: TextStyle(
                            color: kGreen,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Search Card ────────────────────────────────────────
  Widget _buildSearchCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('WHERE ARE YOU GOING?',
              style: TextStyle(
                  color: Colors.white38, fontSize: 10, letterSpacing: 2)),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search destination...',
              hintStyle: const TextStyle(color: Colors.white24),
              prefixIcon: const Icon(Icons.search, color: kAccent, size: 20),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: kAccent),
                    )
                  : _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close,
                              color: Colors.white38, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {
                              _suggestions    = [];
                              _showSuggestions = false;
                            });
                          },
                        )
                      : null,
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: kAccent, width: 1.5)),
            ),
            onChanged: (v) {
              _searchDestination(v);
              setState(() => _showSuggestions = true);
            },
          ),

          // Suggestions dropdown
          if (_showSuggestions && _suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kAccent.withOpacity(0.3)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _suggestions.length.clamp(0, 5),
                separatorBuilder: (_, __) =>
                    const Divider(color: Colors.white12, height: 1),
                itemBuilder: (_, i) {
                  final s    = _suggestions[i];
                  final name = s['display_name']?.toString() ?? '';
                  final short = name.split(',').take(2).join(', ');
                  final full  = name.split(',').skip(2).take(2).join(', ');
                  return ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.place, color: kAccent, size: 18),
                    title: Text(short,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                    subtitle: full.isNotEmpty
                        ? Text(full,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11))
                        : null,
                    onTap: () => _selectDestination(s),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Destination Card ───────────────────────────────────
  Widget _buildDestCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kGreen.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGreen.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: kGreen.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.location_pin, color: kGreen, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('DESTINATION',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        letterSpacing: 2)),
                const SizedBox(height: 2),
                Text(_destName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => setState(() {
              _destLat  = 0;
              _destLng  = 0;
              _destName = '';
              _searchCtrl.clear();
              _progress = 0;
              _remainingM = 0;
              _setStatus('📍 Ready — Search destination');
            }),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  // ── Traffic Card ───────────────────────────────────────
  Widget _buildTrafficCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _trafficColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _trafficColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.traffic, color: _trafficColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TRAFFIC',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        letterSpacing: 2)),
                const SizedBox(height: 2),
                Text(_trafficStatus,
                    style: TextStyle(
                        color: _trafficColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (_osrmDistanceM > 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${(_osrmDistanceM / 1000).toStringAsFixed(1)} km',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                Text('${(_osrmDurationSec / 60).toInt()} min',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              ],
            ),
        ],
      ),
    );
  }

  // ── Status Card ────────────────────────────────────────
  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [kAccent.withOpacity(0.15), kCard],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kAccent.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
              color: kAccent.withOpacity(0.1), blurRadius: 20),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kAccent.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.psychology, color: kAccent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AI STATUS',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                        letterSpacing: 2)),
                const SizedBox(height: 2),
                Text(_status,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Progress Card ──────────────────────────────────────
  Widget _buildProgressCard() {
    final progressColor = _progress > 0.8
        ? kGreen
        : _progress > 0.5
            ? kCyan
            : kAccent;

    return _card(
      child: Column(
        children: [
          // Progress header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('JOURNEY PROGRESS',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 10, letterSpacing: 2)),
              Text('${(_progress * 100).toInt()}%',
                  style: TextStyle(
                      color: progressColor,
                      fontWeight: FontWeight.w900,
                      fontSize: 16)),
            ],
          ),
          const SizedBox(height: 10),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 10,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(progressColor),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Start',
                  style: TextStyle(color: Colors.white24, fontSize: 9)),
              Text(_destName.split(',').first,
                  style: const TextStyle(
                      color: Colors.white24, fontSize: 9)),
            ],
          ),

          const SizedBox(height: 16),

          // Metrics row
          Row(
            children: [
              Expanded(
                child: _metricTile(
                  '📍',
                  'Distance',
                  _remainingM >= 1000
                      ? '${(_remainingM / 1000).toStringAsFixed(1)} km'
                      : '${_remainingM.toInt()} m',
                ),
              ),
              _divider(),
              Expanded(
                child: _metricTile(
                  '⚡',
                  'Speed',
                  '${_speedKmh.toStringAsFixed(0)} km/h',
                ),
              ),
              _divider(),
              Expanded(
                child: _metricTile(
                  '⏱️',
                  'ETA',
                  '${_etaMinutes.toInt()} min',
                ),
              ),
            ],
          ),

          // Traffic delay
          if (_trafficDelaySec > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: kYellow.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kYellow.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber, color: kYellow, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'Traffic delay: +${(_trafficDelaySec / 60).toInt()} min',
                    style: const TextStyle(
                        color: kYellow, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Start / Stop Button ────────────────────────────────
  Widget _buildStartStopButton() {
    return ScaleTransition(
      scale: _running ? _pulseAnim : const AlwaysStoppedAnimation(1.0),
      child: GestureDetector(
        onTap: _running ? _stopJourney : _startJourney,
        child: Container(
          width: double.infinity,
          height: 64,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _running
                  ? [kRed.withOpacity(0.8), kRed]
                  : [kAccent.withOpacity(0.8), kAccent],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: (_running ? kRed : kAccent).withOpacity(0.4),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _running ? Icons.stop_circle : Icons.navigation,
                color: Colors.white,
                size: 26,
              ),
              const SizedBox(width: 10),
              Text(
                _running ? 'STOP JOURNEY' : 'START JOURNEY',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Alarm Dialog ───────────────────────────────────────
  Widget _buildAlarmDialog() {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: kGreen, width: 2),
          boxShadow: [
            BoxShadow(
                color: kGreen.withOpacity(0.3), blurRadius: 40, spreadRadius: 5),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎯', style: TextStyle(fontSize: 52)),
            const SizedBox(height: 12),
            const Text('DESTINATION REACHED!',
                style: TextStyle(
                    color: kGreen,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(_destName,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await _player.stop();
                      Navigator.pop(context);
                      _stopJourney();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Dismiss'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await _player.stop();
                      Navigator.pop(context);
                      _stopJourney();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGreen,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Done! ✓',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Helper Widgets ─────────────────────────────────────
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

  Widget _metricTile(String emoji, String label, String value) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14)),
        Text(label,
            style:
                const TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    );
  }

  Widget _divider() {
    return Container(width: 1, height: 40, color: Colors.white12);
  }
}