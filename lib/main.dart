import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'destination_page.dart';
import 'women_safety_page.dart';
import 'driver_page.dart';
import 'mechanic_page.dart';
import 'highway_page.dart';
void main() {
  runApp(const StopSafeApp());
}

class StopSafeApp extends StatelessWidget {
  const StopSafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }
}

////////////////////////////////////////////////////////////
/// HOME PAGE
////////////////////////////////////////////////////////////

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Widget card(BuildContext context, String title, IconData icon, Widget page) {
    return GestureDetector(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => page)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [Colors.redAccent, Colors.orange],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40),
            const SizedBox(height: 10),
            Text(title, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("OMNIVIA")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 15,
          mainAxisSpacing: 15,
          children: [
            card(context, "AI Destination Alarm", Icons.location_on,
    const DestinationPage()),

card(context, "Women Safety", Icons.security,
    const WomenSafetyPage()),

card(context, "Driver AI", Icons.directions_car,
    const DriverPage()),

// 🔥 ADD THIS
card(context, "Mechanic", Icons.build,
    const MechanicPage()),

// 🔥 ADD THIS
card(context, "Highway Pack", Icons.map,
    const HighwayPage()),
          ],
        ),
      ),
    );
  }
}

////////////////////////////////////////////////////////////
/// COMMON LAYOUT
////////////////////////////////////////////////////////////

Widget simpleLayout(BuildContext context, String title, Widget child) {
  return Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Center(child: SingleChildScrollView(child: child)),
    ),
  );
}