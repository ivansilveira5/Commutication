import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../main.dart'; 

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _topicsController = TextEditingController();
  TimeOfDay? _selectedTime;
  double _targetDuration = 10.0;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    tz.initializeTimeZones();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final doc = await FirebaseFirestore.instance.doc('settings/user_preferences').get();
      if (doc.exists) {
        if (mounted) {
          setState(() {
            _topicsController.text = doc.data()?['topics'] ?? '';
            _targetDuration = (doc.data()?['target_duration_minutes'] ?? 10.0).toDouble();
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading preferences: $e");
    }
  }

  Future<void> _savePreferences() async {
    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.doc('settings/user_preferences').set({
        'topics': _topicsController.text,
        'target_duration_minutes': _targetDuration,
      }, SetOptions(merge: true));

      if (_selectedTime != null && mounted) {
        await _scheduleNotification(_selectedTime!);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preferences saved successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving preferences: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _scheduleNotification(TimeOfDay time) async {
    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
        tz.local, now.year, now.month, now.day, time.hour, time.minute);
    
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    await flutterLocalNotificationsPlugin.zonedSchedule(
      id: 0,
      title: 'Your daily Commutication is ready',
      body: 'Tap to listen to your AI-generated news podcast.',
      scheduledDate: scheduledDate,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_reminder',
          'Daily Reminder',
          channelDescription: 'Daily commute podcast reminder',
          importance: Importance.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Your Interests', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _topicsController,
              decoration: const InputDecoration(
                hintText: 'e.g. Technology, AI, Startups',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Audio Duration', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('${_targetDuration.round()} min', style: const TextStyle(fontSize: 16)),
              ],
            ),
            Slider(
              value: _targetDuration,
              min: 2,
              max: 15,
              divisions: 13,
              label: '${_targetDuration.round()} min',
              onChanged: (double value) {
                setState(() {
                  _targetDuration = value;
                });
              },
            ),
            const SizedBox(height: 24),
            const Text('Daily Notification', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              title: const Text('Set Reminder Time'),
              subtitle: Text(_selectedTime != null 
                ? _selectedTime!.format(context) 
                : 'Not set'),
              trailing: const Icon(Icons.access_time),
              onTap: _pickTime,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              tileColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: _isLoading ? null : _savePreferences,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
              child: _isLoading 
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save Settings', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
