import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:rxdart/rxdart.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  Map<String, dynamic>? _metadata;
  bool _isLoading = true;
  String? _error;

  final String metadataUrl = 'https://raw.githubusercontent.com/ivansilveira5/Commutication/main/Backend/latest_metadata.json';
  final String audioBaseUrl = 'https://raw.githubusercontent.com/ivansilveira5/Commutication/main/Backend/';

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      final response = await http.get(Uri.parse(metadataUrl));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _metadata = data;
          // Keep loading true while the audio file is downloaded/cached
        });
        await _setupAudioPlayer(data['audio_filename']);
      } else {
        throw Exception('Failed to load metadata');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _setupAudioPlayer(String? filename) async {
    if (filename == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    
    try {
      final url = audioBaseUrl + filename;
      final dir = await getApplicationDocumentsDirectory();
      final localFile = File('${dir.path}/$filename');
      
      Uri audioUri;
      if (await localFile.exists()) {
        debugPrint("Playing from local cache: ${localFile.path}");
        audioUri = Uri.file(localFile.path);
      } else {
        debugPrint("Downloading audio from network: $url");
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          await localFile.writeAsBytes(response.bodyBytes);
          debugPrint("Cached locally at: ${localFile.path}");
          audioUri = Uri.file(localFile.path);
        } else {
          debugPrint("Failed to download ($response.statusCode), falling back to streaming.");
          audioUri = Uri.parse(url);
        }
      }
      
      await _player.setAudioSource(
        AudioSource.uri(
          audioUri,
          tag: MediaItem(
            id: '1',
            album: 'Commutication Daily',
            title: filename,
          ),
        ),
      );
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint("Error loading audio: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(body: Center(child: Text('Error: $_error')));
    }

    final topicsRaw = _metadata?['topics'];
    final topics = topicsRaw is List 
        ? topicsRaw.map((e) => e.toString()).join(', ') 
        : (topicsRaw?.toString() ?? 'No topics');
    final headlines = List<String>.from(_metadata?['headlines'] ?? []);

    return Scaffold(
      appBar: AppBar(title: const Text('Commutication'), centerTitle: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Today\'s Focus', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(topics, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Headlines', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: headlines.length,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: const Icon(Icons.article),
                  title: Text(headlines[index]),
                  trailing: IconButton(
                    icon: const Icon(Icons.troubleshoot),
                    tooltip: 'Deep Dive Tomorrow',
                    onPressed: () async {
                      try {
                        await FirebaseFirestore.instance.doc('settings/user_preferences').set(
                          {'deep_dive_topic': headlines[index]},
                          SetOptions(merge: true)
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Deep Dive scheduled for tomorrow!')),
                          );
                        }
                      } catch (e) {
                         debugPrint('Deep dive error: $e');
                      }
                    },
                  ),
                );
              },
            ),
          ),
          _buildPlayer(),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<PositionData>(
            stream: _positionDataStream,
            builder: (context, snapshot) {
              final positionData = snapshot.data;
              final position = positionData?.position ?? Duration.zero;
              final duration = positionData?.duration ?? Duration.zero;
              
              String formatDuration(Duration d) {
                final hours = d.inHours;
                final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
                final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
                if (hours > 0) return '$hours:$minutes:$seconds';
                return '$minutes:$seconds';
              }

              final maxVal = duration.inMilliseconds.toDouble();
              final currentVal = position.inMilliseconds.toDouble();
              final safeMax = maxVal > 0.0 ? maxVal : 100.0;

              return Column(
                children: [
                  Slider(
                    value: currentVal.clamp(0.0, safeMax),
                    max: safeMax,
                    onChanged: (value) {
                      _player.seek(Duration(milliseconds: value.round()));
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(formatDuration(position), style: Theme.of(context).textTheme.bodySmall),
                        Text(formatDuration(duration), style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snapshot) {
              final playerState = snapshot.data;
              final processingState = playerState?.processingState;
              final playing = playerState?.playing;
              
              Widget playPauseButton;
              if (processingState == ProcessingState.loading ||
                  processingState == ProcessingState.buffering) {
                playPauseButton = Container(
                  margin: const EdgeInsets.all(8.0),
                  width: 64.0,
                  height: 64.0,
                  child: const CircularProgressIndicator(),
                );
              } else if (playing != true) {
                playPauseButton = IconButton(
                  icon: const Icon(Icons.play_arrow),
                  iconSize: 64.0,
                  onPressed: _player.play,
                );
              } else if (processingState != ProcessingState.completed) {
                playPauseButton = IconButton(
                  icon: const Icon(Icons.pause),
                  iconSize: 64.0,
                  onPressed: _player.pause,
                );
              } else {
                playPauseButton = IconButton(
                  icon: const Icon(Icons.replay),
                  iconSize: 64.0,
                  onPressed: () => _player.seek(Duration.zero),
                );
              }

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.replay_5),
                    iconSize: 48.0,
                    onPressed: () {
                      final currentPosition = _player.position;
                      _player.seek(currentPosition - const Duration(seconds: 5));
                    },
                  ),
                  playPauseButton,
                  IconButton(
                    icon: const Icon(Icons.forward_5),
                    iconSize: 48.0,
                    onPressed: () {
                      final currentPosition = _player.position;
                      _player.seek(currentPosition + const Duration(seconds: 5));
                    },
                  ),
                  StreamBuilder<double>(
                    stream: _player.speedStream,
                    builder: (context, speedSnapshot) {
                      final currentSpeed = speedSnapshot.data ?? 1.0;
                      return TextButton(
                        onPressed: () {
                          if (currentSpeed == 1.0) {
                            _player.setSpeed(1.2);
                          } else if (currentSpeed == 1.2) {
                            _player.setSpeed(1.5);
                          } else if (currentSpeed == 1.5) {
                            _player.setSpeed(2.0);
                          } else {
                            _player.setSpeed(1.0);
                          }
                        },
                        child: Text(
                          "${currentSpeed}x",
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Stream<PositionData> get _positionDataStream =>
      Rx.combineLatest2<Duration, Duration?, PositionData>(
          _player.positionStream,
          _player.durationStream,
          (position, duration) => PositionData(position, duration ?? Duration.zero));
}

class PositionData {
  final Duration position;
  final Duration duration;
  PositionData(this.position, this.duration);
}
