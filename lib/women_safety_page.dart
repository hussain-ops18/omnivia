import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

///////////////////////////////////////////////////////////
/// OMNIVIA WOMEN SAFETY SYSTEM - Full Version
/// Features:
///   1. Accelerometer trigger (sudden shake)
///   2. Battery low trigger
///   3. Bluetooth + WiFi Follower Detection (AirGuard style)
///   4. Panic Button (manual SOS)
///   5. Safe Walk Timer
///////////////////////////////////////////////////////////

class WomenSafetyPage extends StatefulWidget {
  const WomenSafetyPage({super.key});

  @override
  State<WomenSafetyPage> createState() => _WomenSafetyPageState();
}

class _WomenSafetyPageState extends State<WomenSafetyPage>
    with TickerProviderStateMixin {

  // ── Controllers ──────────────────────────────────────
  final phoneController    = TextEditingController();
  final emailController    = TextEditingController();
  final walkMinController  = TextEditingController(text: '10');

  // ── Core state ────────────────────────────────────────
  final Battery battery    = Battery();
  bool monitoring          = false;
  bool emergencyTriggered  = false;
  String status            = "System Idle";

  // ── Subscriptions ─────────────────────────────────────
  StreamSubscription? accelSubscription;
  StreamSubscription? btScanSubscription;
  Timer? safeWalkTimer;
  Timer? followerScanTimer;

  // ── Animation ─────────────────────────────────────────
  late AnimationController pulseController;
  late Animation<double>   pulseAnimation;

  // ── Follower Detection ────────────────────────────────
  // Each entry: { 'name': String, 'locations': [locationIndex] }
  // locationIndex = scan round number (0,1,2...)
  final Map<String, Set<int>> _btFingerprint   = {};
  final Map<String, Set<int>> _wifiFingerprint = {};
  int _scanRound = 0;
  static const int _followerThreshold = 3; // seen in 3 different rounds

  // ── Safe Walk ─────────────────────────────────────────
  int _safeWalkSecondsLeft = 0;

  ////////////////////////////////////////////////////////////
  @override
  void initState() {
    super.initState();
    pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    pulseAnimation = Tween<double>(begin: 0.95, end: 1.05)
        .animate(CurvedAnimation(parent: pulseController, curve: Curves.easeInOut));
  }

  ////////////////////////////////////////////////////////////
  // 1. START MONITORING
  ////////////////////////////////////////////////////////////
  void startMonitoring() {
    if (phoneController.text.isEmpty || emailController.text.isEmpty) {
      _setStatus("⚠️ Enter Phone & Email First");
      return;
    }
    setState(() {
      monitoring         = true;
      emergencyTriggered = false;
      status             = "🛡️ AI Monitoring Active";
    });

    _checkBattery();
    _detectHarshMovement();
    _startFollowerDetection();

    final walkMins = int.tryParse(walkMinController.text) ?? 10;
    _startSafeWalkTimer(walkMins);
  }

  ////////////////////////////////////////////////////////////
  // 2. STOP MONITORING
  ////////////////////////////////////////////////////////////
  void stopMonitoring() {
    accelSubscription?.cancel();
    btScanSubscription?.cancel();
    followerScanTimer?.cancel();
    safeWalkTimer?.cancel();
    FlutterBluePlus.stopScan();
    setState(() {
      monitoring             = false;
      emergencyTriggered     = false;
      status                 = "System Idle";
      _btFingerprint.clear();
      _wifiFingerprint.clear();
      _scanRound             = 0;
      _safeWalkSecondsLeft   = 0;
    });
  }

  ////////////////////////////////////////////////////////////
  // 3. BATTERY CHECK
  ////////////////////////////////////////////////////////////
  void _checkBattery() async {
    while (monitoring && !emergencyTriggered) {
      int level = await battery.batteryLevel;
      if (level <= 15) {
        emergencyTriggered = true;
        _sendEmergency("🔋 Battery Low Emergency! (${level}%)");
        break;
      }
      await Future.delayed(const Duration(seconds: 30));
    }
  }

  ////////////////////////////////////////////////////////////
  // 4. ACCELEROMETER — harsh movement
  ////////////////////////////////////////////////////////////
  void _detectHarshMovement() {
    accelSubscription = accelerometerEvents.listen((event) {
      if (!monitoring || emergencyTriggered) return;
      double force = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      if (force > 20) {
        emergencyTriggered = true;
        _sendEmergency("📳 Sudden Disturbance Detected!");
      }
    });
  }

  ////////////////////////////////////////////////////////////
  // 5. FOLLOWER DETECTION (Bluetooth + WiFi fingerprinting)
  //    AirGuard-style: same signal seen in 3+ scan rounds
  //    across different locations = ALERT
  ////////////////////////////////////////////////////////////
  void _startFollowerDetection() {
    // Scan every 45 seconds (new location assumed each round)
    followerScanTimer = Timer.periodic(const Duration(seconds: 45), (_) async {
      if (!monitoring || emergencyTriggered) return;
      _scanRound++;
      await _scanBluetooth();
      await _scanWifi();
      _checkFollower();
    });

    // First scan immediately
    Future.delayed(const Duration(seconds: 5), () async {
      if (!monitoring) return;
      _scanRound++;
      await _scanBluetooth();
      await _scanWifi();
    });
  }

  // ── Bluetooth scan ──────────────────────────────────
  Future<void> _scanBluetooth() async {
    try {
      if (await FlutterBluePlus.isSupported == false) return;

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

      final results = FlutterBluePlus.lastScanResults;
      for (final r in results) {
        final name = r.device.platformName.trim();
        if (name.isEmpty) continue; // skip unnamed devices
        _btFingerprint.putIfAbsent(name, () => {}).add(_scanRound);
      }

      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  // ── WiFi scan ────────────────────────────────────────
  Future<void> _scanWifi() async {
    try {
      final can = await WiFiScan.instance.canStartScan(askPermissions: true);
      if (can != CanStartScan.yes) return;

      await WiFiScan.instance.startScan();
      final results = await WiFiScan.instance.getScannedResults();

      for (final ap in results) {
        final ssid = ap.ssid.trim();
        if (ssid.isEmpty) continue;
        _wifiFingerprint.putIfAbsent(ssid, () => {}).add(_scanRound);
      }
    } catch (_) {}
  }

  // ── Check if any signal appeared in 3+ rounds ────────
  void _checkFollower() {
    if (emergencyTriggered) return;

    // Check Bluetooth
    for (final entry in _btFingerprint.entries) {
      if (entry.value.length >= _followerThreshold) {
        _silentFollowerAlert("Bluetooth: ${entry.key}");
        return;
      }
    }

    // Check WiFi
    for (final entry in _wifiFingerprint.entries) {
      if (entry.value.length >= _followerThreshold) {
        _silentFollowerAlert("WiFi Hotspot: ${entry.key}");
        return;
      }
    }
  }

  // ── Silent alert to user (follower doesn't know) ─────
  void _silentFollowerAlert(String signal) {
    if (!mounted) return;

    // Vibrate silently
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 400), () => HapticFeedback.heavyImpact());
    Future.delayed(const Duration(milliseconds: 800), () => HapticFeedback.heavyImpact());

    _setStatus("⚠️ Possible Follower Detected!");

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A0A0A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 8),
            Text("⚠️ Possible Follower",
                style: TextStyle(color: Colors.orange, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "The same device has been detected near you across multiple locations.",
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 12),
            Text(
              "Signal: $signal",
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
            const SizedBox(height: 16),
            const Text(
              "What do you want to do?",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // Clear this signal so it doesn't re-trigger immediately
              _btFingerprint.removeWhere((k, v) => "Bluetooth: $k" == signal);
              _wifiFingerprint.removeWhere((k, v) => "WiFi Hotspot: $k" == signal);
              _setStatus("🛡️ AI Monitoring Active");
            },
            child: const Text("I'm Safe", style: TextStyle(color: Colors.green)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              emergencyTriggered = true;
              _sendEmergency("👁️ Possible Follower Detected! ($signal)");
            },
            child: const Text("Send SOS!", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  ////////////////////////////////////////////////////////////
  // 6. SAFE WALK TIMER
  ////////////////////////////////////////////////////////////
  void _startSafeWalkTimer(int minutes) {
    _safeWalkSecondsLeft = minutes * 60;
    safeWalkTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!monitoring || emergencyTriggered) {
        t.cancel();
        return;
      }
      setState(() => _safeWalkSecondsLeft--);

      if (_safeWalkSecondsLeft <= 0) {
        t.cancel();
        // Show "Are you safe?" check-in
        _safeWalkCheckIn();
      }
    });
  }

  void _safeWalkCheckIn() {
    if (!mounted) return;
    HapticFeedback.heavyImpact();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0A1A0A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("🚶 Safe Walk Check-In",
            style: TextStyle(color: Colors.greenAccent)),
        content: const Text(
          "Your Safe Walk time is up.\nAre you safe?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              emergencyTriggered = true;
              _sendEmergency("⏱️ Safe Walk Timer Expired — No Response!");
            },
            child: const Text("SOS!", style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () {
              Navigator.pop(context);
              // Restart timer
              final mins = int.tryParse(walkMinController.text) ?? 10;
              _startSafeWalkTimer(mins);
              _setStatus("🛡️ AI Monitoring Active");
            },
            child: const Text("I'm Safe ✓", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  ////////////////////////////////////////////////////////////
  // 7. MANUAL PANIC BUTTON
  ////////////////////////////////////////////////////////////
  void _manualSOS() {
    if (!monitoring) {
      _setStatus("⚠️ Start Monitoring First!");
      return;
    }
    emergencyTriggered = true;
    _sendEmergency("🔴 Manual SOS Triggered!");
  }

  ////////////////////////////////////////////////////////////
  // 8. SEND EMERGENCY
  ////////////////////////////////////////////////////////////
  void _sendEmergency(String reason) async {
    if (!mounted) return;

    HapticFeedback.heavyImpact();
    _setStatus("📍 Fetching Location...");

    LocationPermission permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      _setStatus("❌ Location Permission Denied");
      return;
    }

    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    String locationLink =
        "https://maps.google.com/?q=${position.latitude},${position.longitude}";

    String message =
        "🚨 OMNIVIA WOMEN SAFETY ALERT\n"
        "Reason: $reason\n"
        "Time: ${DateTime.now().toLocal()}\n"
        "Live Location:\n$locationLink";

    // ── SMS ──────────────────────────────────────────────
    final Uri smsUri = Uri.parse(
        "sms:${phoneController.text}?body=${Uri.encodeComponent(message)}");
    if (await canLaunchUrl(smsUri)) await launchUrl(smsUri);

    // ── Email ─────────────────────────────────────────────
    final Uri emailUri = Uri.parse(
        "mailto:${emailController.text}"
        "?subject=${Uri.encodeComponent('🚨 OMNIVIA Emergency Alert')}"
        "&body=${Uri.encodeComponent(message)}");
    if (await canLaunchUrl(emailUri)) await launchUrl(emailUri);

    if (!mounted) return;

    // ── Popup ─────────────────────────────────────────────
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A0000),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text("🚨 Emergency Alert Sent",
            style: TextStyle(color: Colors.red)),
        content: Text(
          "Reason: $reason\n\nSMS & Email apps opened.\nPress send to alert your contact.",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    _setStatus("🚨 Emergency Alert Triggered");
    stopMonitoring();
  }

  ////////////////////////////////////////////////////////////
  // HELPERS
  ////////////////////////////////////////////////////////////
  void _setStatus(String s) {
    if (mounted) setState(() => status = s);
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  @override
  void dispose() {
    accelSubscription?.cancel();
    btScanSubscription?.cancel();
    followerScanTimer?.cancel();
    safeWalkTimer?.cancel();
    pulseController.dispose();
    phoneController.dispose();
    emailController.dispose();
    walkMinController.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  ////////////////////////////////////////////////////////////
  // UI
  ////////////////////////////////////////////////////////////
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.shield, color: Color(0xFFFF3366), size: 22),
            SizedBox(width: 8),
            Text(
              "Women Safety",
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
          if (monitoring)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green, width: 1),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.circle, color: Colors.green, size: 8),
                    SizedBox(width: 4),
                    Text("LIVE", style: TextStyle(color: Colors.green, fontSize: 12)),
                  ],
                ),
              ),
            )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [

            // ── Status Card ─────────────────────────────
            _buildStatusCard(),

            const SizedBox(height: 20),

            // ── Input Fields ─────────────────────────────
            _buildInputCard(),

            const SizedBox(height: 20),

            // ── Safe Walk Timer ───────────────────────────
            _buildSafeWalkCard(),

            const SizedBox(height: 20),

            // ── Start / Stop ──────────────────────────────
            _buildStartStopButton(),

            const SizedBox(height: 20),

            // ── PANIC BUTTON ──────────────────────────────
            _buildPanicButton(),

            const SizedBox(height: 20),

            // ── Feature List ──────────────────────────────
            _buildFeatureList(),

          ],
        ),
      ),
    );
  }

  // ── Status Card ────────────────────────────────────────
  Widget _buildStatusCard() {
    Color statusColor = Colors.grey;
    if (status.contains("🚨")) statusColor = Colors.red;
    else if (status.contains("⚠️")) statusColor = Colors.orange;
    else if (status.contains("🛡️")) statusColor = Colors.green;
    else if (status.contains("📍")) statusColor = Colors.blue;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withOpacity(0.4), width: 1.5),
      ),
      child: Column(
        children: [
          Icon(
            monitoring ? Icons.radar : Icons.shield_outlined,
            color: statusColor,
            size: 36,
          ),
          const SizedBox(height: 8),
          Text(
            status,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          if (monitoring && _safeWalkSecondsLeft > 0) ...[
            const SizedBox(height: 8),
            Text(
              "⏱️ Safe Walk: ${_formatTime(_safeWalkSecondsLeft)}",
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
          if (monitoring && _scanRound > 0) ...[
            const SizedBox(height: 4),
            Text(
              "🔍 Scan Round: $_scanRound | BT Signals: ${_btFingerprint.length} | WiFi: ${_wifiFingerprint.length}",
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  // ── Input Card ─────────────────────────────────────────
  Widget _buildInputCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Trusted Contact",
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: phoneController,
            label: "Phone Number",
            icon: Icons.phone,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: emailController,
            label: "Email Address",
            icon: Icons.email,
            keyboardType: TextInputType.emailAddress,
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white38),
        prefixIcon: Icon(icon, color: const Color(0xFFFF3366), size: 20),
        filled: true,
        fillColor: const Color(0xFF222222),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFF3366), width: 1.5),
        ),
      ),
    );
  }

  // ── Safe Walk Card ─────────────────────────────────────
  Widget _buildSafeWalkCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1A0A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_walk, color: Colors.green, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Safe Walk Timer",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                Text("Auto alert if not checked-in",
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              controller: walkMinController,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                suffix: const Text("min", style: TextStyle(color: Colors.white38, fontSize: 11)),
                filled: true,
                fillColor: const Color(0xFF1A2A1A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Start / Stop Button ────────────────────────────────
  Widget _buildStartStopButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: monitoring ? stopMonitoring : startMonitoring,
        style: ElevatedButton.styleFrom(
          backgroundColor: monitoring ? const Color(0xFF2A0A0A) : const Color(0xFF1A2A1A),
          foregroundColor: monitoring ? Colors.red : Colors.green,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: monitoring ? Colors.red : Colors.green,
              width: 1.5,
            ),
          ),
          elevation: 0,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(monitoring ? Icons.stop_circle : Icons.play_circle, size: 24),
            const SizedBox(width: 10),
            Text(
              monitoring ? "Stop Monitoring" : "Start AI Monitoring",
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  // ── Panic Button ───────────────────────────────────────
  Widget _buildPanicButton() {
    return ScaleTransition(
      scale: monitoring ? pulseAnimation : const AlwaysStoppedAnimation(1.0),
      child: GestureDetector(
        onTap: _manualSOS,
        child: Container(
          width: double.infinity,
          height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFFFF3366),
            borderRadius: BorderRadius.circular(20),
            boxShadow: monitoring
                ? [
                    BoxShadow(
                      color: const Color(0xFFFF3366).withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 2,
                    )
                  ]
                : [],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sos, color: Colors.white, size: 32),
              SizedBox(width: 12),
              Text(
                "PANIC / SOS",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Feature List ───────────────────────────────────────
  Widget _buildFeatureList() {
    final features = [
      ("📳", "Shake Detection", "Sudden movement auto alert"),
      ("🔋", "Battery Guard", "Alert when battery < 15%"),
      ("👁️", "Follower Detection", "BT + WiFi signal tracking"),
      ("⏱️", "Safe Walk Timer", "Check-in or auto alert"),
      ("🔴", "Panic Button", "One tap SOS"),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "ACTIVE SHIELDS",
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          ...features.map((f) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Text(f.$1, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(f.$2,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                          Text(f.$3,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12)),
                        ],
                      ),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: monitoring ? Colors.green : Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    )
                  ],
                ),
              )),
        ],
      ),
    );
  }
}