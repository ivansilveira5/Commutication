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
  List<String> _topics = [];
  bool _recommendExtra = true;
  String _podcastVibe = 'Banter';
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
            final topicsData = doc.data()?['topics'];
            if (topicsData is List) {
              _topics = List<String>.from(topicsData);
            } else if (topicsData is String && topicsData.isNotEmpty) {
              _topics = topicsData.split(',').map((e) => e.trim()).toList();
            } else {
              _topics = [];
            }
            
            _recommendExtra = doc.data()?['recommend_extra'] ?? true;
            _podcastVibe = doc.data()?['podcast_vibe'] ?? 'Banter';
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
        'topics': _topics,
        'recommend_extra': _recommendExtra,
        'podcast_vibe': _podcastVibe,
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Your Interests', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8.0,
              runSpacing: 4.0,
              children: _topics.map((topic) {
                return Chip(
                  label: Text(topic),
                  onDeleted: () {
                    setState(() {
                      _topics.remove(topic);
                    });
                  },
                );
              }).toList(),
            ),
            TextField(
              controller: _topicsController,
              decoration: const InputDecoration(
                hintText: 'Type an interest and press comma or enter',
              ),
              onChanged: (value) {
                if (value.endsWith(',')) {
                  final newTopic = value.substring(0, value.length - 1).trim();
                  if (newTopic.isNotEmpty && !_topics.contains(newTopic)) {
                    setState(() {
                      _topics.add(newTopic);
                    });
                  }
                  _topicsController.clear();
                }
              },
              onSubmitted: (value) {
                final newTopic = value.trim();
                if (newTopic.isNotEmpty && !_topics.contains(newTopic)) {
                  setState(() {
                    _topics.add(newTopic);
                  });
                }
                _topicsController.clear();
              },
            ),
            CheckboxListTile(
              title: const Text('Accept recommended topics'),
              subtitle: const Text('AI will find extra news to fill time if needed'),
              value: _recommendExtra,
              onChanged: (bool? value) {
                setState(() {
                  _recommendExtra = value ?? true;
                });
              },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 24),
            const Text('Podcast Vibe', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _podcastVibe,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'Banter', child: Text('Alex & Sam (Tech Banter)')),
                DropdownMenuItem(value: 'News Anchor', child: Text('Marcus (Serious News Desk)')),
                DropdownMenuItem(value: 'Comedy', child: Text('Zoe & Liam (Morning Radio Comedy)')),
              ],
              onChanged: (String? newValue) {
                if (newValue != null) {
                  setState(() {
                    _podcastVibe = newValue;
                  });
                }
              },
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
            const SizedBox(height: 32),
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
