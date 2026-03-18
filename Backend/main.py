import os
import json
import base64
import wave
import time
import glob
from pydub import AudioSegment
from datetime import datetime, timedelta
import firebase_admin
from firebase_admin import credentials, firestore
from google import genai
from google.genai import types, errors

def init_firebase():
    creds_json = os.environ.get("FIREBASE_CREDENTIALS")
    if creds_json:
        creds_dict = json.loads(creds_json)
        cred = credentials.Certificate(creds_dict)
        firebase_admin.initialize_app(cred)
    else:
        print("Warning: FIREBASE_CREDENTIALS not found in environment.")

def get_preferences():
    try:
        db = firestore.client()
        doc_ref = db.collection('settings').document('user_preferences')
        doc = doc_ref.get()
        if doc.exists:
            data = doc.to_dict()
            topics_data = data.get('topics', ['Technology', 'World News', 'Science'])
            if isinstance(topics_data, str):
                topics = [t.strip() for t in topics_data.split(',') if t.strip()]
            else:
                topics = topics_data
            if not topics:
                topics = ['Technology', 'World News', 'Science']
                
            duration = data.get('target_duration_minutes', 10.0)
            recommend_extra = data.get('recommend_extra', True)
            podcast_vibe = data.get('podcast_vibe', 'Banter')
            deep_dive_topic = data.get('deep_dive_topic')
            
            # Consume the deep dive flag so it only runs once
            if deep_dive_topic:
                doc_ref.update({'deep_dive_topic': firestore.DELETE_FIELD})
                
            return topics, int(duration), recommend_extra, podcast_vibe, deep_dive_topic
        else:
            return ['Technology', 'World News', 'Science'], 10, True, 'Banter', None
    except Exception as e:
        print(f"Error fetching preferences: {e}")
        return ['Technology', 'World News', 'Science'], 10, True, 'Banter', None

def get_gemini_client():
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("GEMINI_API_KEY not set")
    return genai.Client(api_key=api_key)

def get_voice_configs_for_vibe(vibe):
    if vibe == 'News Anchor':
        return [
            types.SpeakerVoiceConfig(
                speaker="Marcus",
                voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Charon"))
            )
        ]
    elif vibe == 'Comedy':
        return [
            types.SpeakerVoiceConfig(
                speaker="Zoe",
                voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Aoede"))
            ),
            types.SpeakerVoiceConfig(
                speaker="Liam",
                voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Fenrir"))
            )
        ]
    else: # Banter
        return [
            types.SpeakerVoiceConfig(
                speaker="Alex",
                voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Puck"))
            ),
            types.SpeakerVoiceConfig(
                speaker="Sam",
                voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore"))
            )
        ]

def generate_script_and_metadata(client, topics, duration_minutes, recommend_extra, podcast_vibe, deep_dive_topic):
    # Average conversational speaking rate is ~150 words per minute
    target_words = duration_minutes * 150
    topics_str = ", ".join(topics) if isinstance(topics, list) else topics
    
    if podcast_vibe == 'News Anchor':
        vibe_prompt = f"Generate a serious, NPR-style solo anchor news broadcast hosted by 'Marcus'. Marcus should be professional, deeply analytical, and speak authoritative monologues. Every spoken line MUST begin with 'Marcus: '."
    elif podcast_vibe == 'Comedy':
        vibe_prompt = f"Generate a chaotic, highly energetic morning-radio comedy podcast transcript between two hosts named 'Zoe' and 'Liam'. They should be making jokes, interrupting each other with witty banter, and finding the humor in the news. Every spoken line MUST begin with the speaker's name (e.g. 'Zoe: ' or 'Liam: ')."
    else:
        vibe_prompt = f"Generate a highly conversational, engaging tech-banter podcast transcript between two hosts named 'Alex' and 'Sam'. They should banter, ask each other questions, and react naturally to the news. Every spoken line MUST begin with the speaker's name (e.g. 'Alex: ' or 'Sam: ')."
        
    prompt = (
        f"{vibe_prompt}\n\n"
        f"CORE DIRECTIVES:\n"
        f"1. TIME LIMIT: The script MUST be exactly structured for a {duration_minutes}-minute audio playback. To achieve this, you MUST generate approximately {target_words} words.\n"
        f"2. PRIMARY INTERESTS: The user's requested topics are: {topics_str}.\n"
        f"3. FILTERING: You must review all gathered information, assess its relative importance, and filter out minor stories. Select only the most impactful news so that the resulting script perfectly fits the word count WITHOUT feeling rushed.\n"
    )
    
    if recommend_extra:
        prompt += (
            f"4. DYNAMIC PADDING & GLOBAL NEWS: The user has enabled 'Recommended Topics'. You MUST independently identify and include the most critical, absolute highest-priority global news headlines of the day across any domain, even if they fall outside the user's explicit interests. Furthermore, if the primary interests do not provide enough compelling material to naturally fill the {duration_minutes} minutes, you must aggressively find and integrate extra, highly engaging global topics.\n"
        )
    else:
        prompt += (
            f"4. STRICT TOPIC COMPLIANCE: The user has disabled 'Recommended Topics'. You MUST strictly confine your discussion ONLY to the user's explicitly stated interests. Do not introduce outside topics. Dive as deep as necessary into these specific topics to naturally expand and fill the {duration_minutes} minutes.\n"
        )
        
    if deep_dive_topic:
        prompt += (
            f"5. SPECIAL DEEP DIVE DIRECTIVE: The user explicitly requested a deep dive on '{deep_dive_topic}'. You MUST dedicate approximately 50% of the entire podcast duration to exhaustively exploring, analyzing, and unpacking all facets, implications, and expert opinions regarding this specific story!"
        )

    prompt += (
        f"\nFORMATTING RULES:\n"
        f"Stop summarizing and instead dive deeply into the nuances, opinions, and implications of the news. "
        f"IMPORTANT: You MUST return ONLY valid raw JSON. All JSON keys (e.g. \"headlines\", \"script\") and string array elements MUST be properly enclosed in double quotes (\"). "
        f"CRITICAL RULE FOR SCRIPT TEXT: Inside the massive text dialogue of the 'script' string, you MUST NEVER use any double quotes (\"). If you need to quote something spoken by the hosts, use single quotes (')! "
        f"The JSON must have exactly these keys: "
        f"\"headlines\" (an array of objects containing exact keys: 'title' (string) and 'timestamp_seconds' (integer). You must intelligently estimate the timestamp_seconds based on where the topic starts in the script, assuming a speaking rate of 150 words per minute. E.g., if a topic starts 300 words into the script, its timestamp is 120.), "
        f"\"script\" (the entire podcast transcript, with absolutely no internal double quotes), and "
        f"\"audio_filename\" (a string formatted exactly as 'news_YYYY-MM-DD.mp3' using today's date)."
    )
    
    response = client.models.generate_content(
        model='gemini-2.5-flash',
        contents=prompt,
        config=types.GenerateContentConfig(
            tools=[{"google_search": {}}],
            temperature=0.7
        )
    )
    
    try:
        response_text = response.text.strip()
        # Safely strip any markdown code blocks if the LLM still returns them
        if response_text.startswith("```"):
            response_text = response_text.split("\n", 1)[-1]
        if response_text.startswith("json\n"):
             response_text = response_text.split("\n", 1)[-1]
        if response_text.endswith("```"):
             response_text = response_text.rsplit("\n", 1)[0]
             
        response_text = response_text.strip()
        
        try:
            content = json.loads(response_text)
        except json.JSONDecodeError as parse_error:
            try:
                # LLM might have used single quotes for JSON keys, so fallback to ast.literal_eval
                import ast
                sanitized = response_text.replace("true", "True").replace("false", "False").replace("null", "None")
                content = ast.literal_eval(sanitized)
            except Exception:
                print(f"Failed to parse JSON string: {response.text}")
                raise ValueError("Failed to parse JSON from Gemini") from parse_error
        # Ensure correct extension fallback in case LLM generates a different one
        filename = content.get("audio_filename", f"news_{datetime.now().strftime('%Y-%m-%d')}.wav")
        if filename.endswith(".mp3"):
            filename = filename.replace(".mp3", ".wav")
        if not filename.endswith(".wav"):
            filename += ".wav"
            
        content["audio_filename"] = filename
        return content
    except Exception as e:
        print(f"Failed to parse JSON string: {response.text}")
        raise ValueError("Failed to parse JSON from Gemini") from e

def split_text_into_chunks(text, max_length=2500):
    """Splits text into chunks, prioritizing paragraph breaks (\n\n) to preserve 'Host: ' tags."""
    paragraphs = text.replace('\r\n', '\n').split('\n\n')
    chunks = []
    current_chunk = ""

    for p in paragraphs:
        p = p.strip()
        if not p:
            continue
            
        # If a single paragraph is larger than max_length, split it by sentences
        if len(p) > max_length:
            # Carry over the host name to the split sentences to not break TTS context
            host_prefix = ""
            if ":" in p and len(p.split(":")[0]) < 20: 
                host_prefix = p.split(":")[0] + ":"
                
            sentences = p.replace('. ', '.[SPLIT]').replace('! ', '![SPLIT]').replace('? ', '?[SPLIT]').split('[SPLIT]')
            for s in sentences:
                s = s.strip()
                if not s: continue
                
                # Re-inject host prefix if it's not the first sentence
                if host_prefix and not s.startswith(host_prefix) and ":" not in s[:20]:
                    s = f"{host_prefix} {s}"
                    
                if len(current_chunk) + len(s) + 1 <= max_length:
                    current_chunk += s + " "
                else:
                    if current_chunk:
                        chunks.append(current_chunk.strip())
                    current_chunk = s + " "
        else:
            if len(current_chunk) + len(p) + 2 <= max_length:
                current_chunk += p + "\n\n"
            else:
                if current_chunk:
                    chunks.append(current_chunk.strip())
                current_chunk = p + "\n\n"
                
    if current_chunk:
        chunks.append(current_chunk.strip())
        
    return chunks

def generate_audio(client, text, filename, podcast_vibe):
    print(f"Generating audio for {filename} (Vibe: {podcast_vibe})...")
    
    chunks = split_text_into_chunks(text)
    full_audio_bytes = bytearray()
    
    print(f"Divided script into {len(chunks)} chunks for TTS processing.")
    
    for i, chunk in enumerate(chunks):
        if not chunk.strip():
            continue
            
        print(f"Processing chunk {i+1}/{len(chunks)}...")
        
        # Max retries with backoff to handle 429 Quota limits
        max_retries = 3
        response = None
        for attempt in range(max_retries):
            try:
                # Generate PCM audio bytes utilizing the requested multi-speaker TTS model
                response = client.models.generate_content(
                    model='gemini-2.5-flash-preview-tts',
                    contents=chunk,
                    config=types.GenerateContentConfig(
                        response_modalities=["AUDIO"],
                        speech_config=types.SpeechConfig(
                            multi_speaker_voice_config=types.MultiSpeakerVoiceConfig(
                                speaker_voice_configs=get_voice_configs_for_vibe(podcast_vibe)
                            )
                        )
                    )
                )
                break # Success! Break out of the retry loop.
            except errors.ClientError as e:
                if e.status == 'RESOURCE_EXHAUSTED' or "429" in str(e):
                    print(f"Rate limited by Google API (429). Taking a 65-second cool-down break before continuing... (Attempt {attempt+1}/{max_retries})")
                    time.sleep(65)
                else:
                    raise e
                    
        if response is None:
            raise RuntimeError(f"Failed to generate audio for chunk {i+1} after {max_retries} attempts due to persistent API errors.")
        
        pcm_data = None
        if getattr(response, 'candidates', None) and response.candidates[0].content.parts:
            for part in response.candidates[0].content.parts:
                # Look for the internal inline_data portion
                if hasattr(part, 'inline_data') and part.inline_data:
                    data = part.inline_data.data
                    # the content can be represented as bytes or base64-encoded string
                    if isinstance(data, str):
                        pcm_data = base64.b64decode(data)
                    else:
                        pcm_data = data
                    break
        
        if pcm_data:
            full_audio_bytes.extend(pcm_data)
        else:
            print(f"Warning: Failed to extract PCM audio data from Gemini response for chunk {i+1}")
            
    if not full_audio_bytes:
        raise RuntimeError("Failed to generate any audio data from the provided script.")
    
    # Default outputs are mostly 24kHz, 1-channel, 16-bit PCM
    wav_filename = filename.replace('.mp3', '.wav')
    with wave.open(wav_filename, 'wb') as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2) # 16-bit width corresponds to 2 bytes
        wav_file.setframerate(24000)
        wav_file.writeframes(full_audio_bytes)
        
    print(f"Compressing {wav_filename} to {filename} using pydub (MP3 64k)...")
    try:
        audio = AudioSegment.from_wav(wav_filename)
        audio.export(filename, format="mp3", bitrate="64k")
        os.remove(wav_filename)
        print(f"Successfully compressed and saved {filename}")
    except Exception as e:
        print(f"Compression failed: {e}. Falling back to keeping the wav.")
        os.rename(wav_filename, filename)


def cleanup_old_files():
    now = datetime.now()
    cutoff_date = now - timedelta(days=7)
    audio_files = glob.glob("*.mp3") + glob.glob("*.wav")
    for f in audio_files:
        try:
            mtime = datetime.fromtimestamp(os.path.getmtime(f))
            if mtime < cutoff_date:
                os.remove(f)
                print(f"Deleted old audio file: {f}")
        except Exception as e:
            print(f"Error checking/deleting file {f}: {e}")

def main():
    # Force execution context from within the Backend directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    
    init_firebase()
    topics, duration_minutes, recommend_extra, podcast_vibe, deep_dive_topic = get_preferences()
    print(f"Preferences retrieved: {topics} ({duration_minutes} mins, Recommended: {recommend_extra}, Vibe: {podcast_vibe}, Deep Dive: {deep_dive_topic})")
    
    client = get_gemini_client()
    
    # 1. AI Generation
    print("Generating script...")
    podcast_data = generate_script_and_metadata(client, topics, duration_minutes, recommend_extra, podcast_vibe, deep_dive_topic)
    print(f"Generated metadata topics array count limits met.")
    
    # 2. Audio Generation
    script_text = podcast_data.get("script", "")
    audio_filename = podcast_data.get("audio_filename")
    
    if script_text and audio_filename:
        generate_audio(client, script_text, audio_filename, podcast_vibe)
    else:
        print("Warning: Skipping audio generation due to missing script text or filename.")
    
    # 3. Storage
    print("Saving latest_metadata.json...")
    podcast_data['topics'] = topics
    with open("latest_metadata.json", "w", encoding="utf-8") as f:
        json.dump(podcast_data, f, indent=4)
        
    # 4. Cleanup
    print("Cleaning up old .wav files...")
    cleanup_old_files()
    print("Run completed successfully.")
    
if __name__ == "__main__":
    main()
