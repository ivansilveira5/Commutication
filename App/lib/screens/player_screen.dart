import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  Map<String, dynamic>? _metadata;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchMetadata();
  }

  // NOTE: Ensure your backend GitHub raw URL is inserted here.
  final String _metadataUrl = 'https://raw.githubusercontent.com/ivansilveira5/Commutication/main/Backend/latest_metadata.json';
  // Note: the backend url would typically host the audio file too.
  
  Future<void> _fetchMetadata() async {
    try {
      final response = await http.get(Uri.parse(_metadataUrl));
      if (response.statusCode == 200) {
        setState(() {
          _metadata = jsonDecode(response.body);
          _isLoading = false;
        });
        _setupAudioPlayer();
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint("Failed to fetch metadata: $e");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _setupAudioPlayer() async {
    if (_metadata == null || !_metadata!.containsKey('audio_filename')) return;
    
    // As per previous plan, assuming audio is hosted online. Wait, you'll need the actual audio URL.
    // E.g., https://raw.githubusercontent.com/.../audio.mp3
    final audioFileName = _metadata!['audio_filename'];
    final audioUrl = 'https://raw.githubusercontent.com/ivansilveira5/Commutication/main/Backend/$audioFileName';
    
    try {
      await _audioPlayer.setUrl(audioUrl);
    } catch (e) {
      debugPrint("Error loading audio: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_metadata == null) {
      return const Scaffold(
        body: Center(child: Text('No metadata found for today.')),
      );
    }

    final headlines = _metadata!['headlines'] as List<dynamic>? ?? [];

    return Scaffold(
        appBar: AppBar(
          title: const Text('Daily Podcast'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Topics covered: ${_metadata!['topics'] ?? 'N/A'}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: headlines.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    leading: const Icon(Icons.article),
                    title: Text(headlines[index].toString()),
                  );
                },
              ),
            ),
            _buildPlayerControls(),
          ],
        ));
  }

  Widget _buildPlayerControls() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          StreamBuilder<PlayerState>(
            stream: _audioPlayer.playerStateStream,
            builder: (context, snapshot) {
              final playerState = snapshot.data;
              final processingState = playerState?.processingState;
              final playing = playerState?.playing;

              if (processingState == ProcessingState.loading ||
                  processingState == ProcessingState.buffering) {
                return const CircularProgressIndicator();
              } else if (playing != true) {
                return IconButton(
                  icon: const Icon(Icons.play_arrow),
                  iconSize: 64.0,
                  onPressed: _audioPlayer.play,
                );
              } else if (processingState != ProcessingState.completed) {
                return IconButton(
                  icon: const Icon(Icons.pause),
                  iconSize: 64.0,
                  onPressed: _audioPlayer.pause,
                );
              } else {
                return IconButton(
                  icon: const Icon(Icons.replay),
                  iconSize: 64.0,
                  onPressed: () => _audioPlayer.seek(Duration.zero),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }
}
