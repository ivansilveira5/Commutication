import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/login_screen.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp();
  
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.ivansilveira.commutication.channel.audio',
    androidNotificationChannelName: 'Audio playback',
    androidNotificationOngoing: true,
    androidNotificationIcon: 'drawable/ic_notification',
  );

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(settings: initializationSettings);

  final prefs = await SharedPreferences.getInstance();
  final userId = prefs.getString('userId');

  runApp(MyApp(initialUserId: userId));
}

class MyApp extends StatelessWidget {
  final String? initialUserId;
  const MyApp({super.key, this.initialUserId});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Commutication',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple, 
          brightness: Brightness.dark,
        ),
      ),
      home: initialUserId == null ? const LoginScreen() : const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  
  static const List<Widget> _widgetOptions = <Widget>[
    PlayerScreen(),
    SettingsScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _widgetOptions.elementAt(_selectedIndex),
      ),
      bottomNavigationBar: NavigationBar(
        onDestinationSelected: _onItemTapped,
        selectedIndex: _selectedIndex,
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Icons.play_arrow),
            label: 'Player',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
