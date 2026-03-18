import os
import json
import base64
import wave
import time
import glob
from datetime import datetime, timedelta
import firebase_admin
from firebase_admin import credentials, firestore
from google import genai
from google.genai import types

def init_firebase():
    creds_json = os.environ.get("FIREBASE_CREDENTIALS")
    if creds_json:
        creds_dict = json.loads(creds_json)
        cred = credentials.Certificate(creds_dict)
        firebase_admin.initialize_app(cred)
    else:
        print("Warning: FIREBASE_CREDENTIALS not found in environment.")

def get_topics():
    try:
        db = firestore.client()
        doc_ref = db.collection('settings').document('user_preferences')
        doc = doc_ref.get()
        if doc.exists:
            data = doc.to_dict()
            return data.get('topics', 'Technology, World News, Science')
        else:
            return 'Technology, World News, Science'
    except Exception as e:
        print(f"Error fetching topics: {e}")
        return 'Technology, World News, Science'

def get_gemini_client():
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("GEMINI_API_KEY not set")
    return genai.Client(api_key=api_key)

def generate_script_and_metadata(client, topics):
    prompt = (
        f"Search the live web for the following topics: {topics}. "
        f"Generate a highly conversational, engaging podcast transcript between two hosts named 'Alex' and 'Sam'. "
        f"The script MUST be a minimum of 2,000 words. Stop summarizing and instead dive deeply into the nuances, opinions, and implications of the news. "
        f"They should banter, ask each other questions, and react to the news. "
        f"Every single spoken line MUST begin with the speaker's name and a colon (e.g., 'Alex: [text]' or 'Sam: [text]'). "
        f"IMPORTANT: You MUST return ONLY valid raw JSON. All JSON keys (e.g. \"headlines\", \"script\") and string array elements MUST be properly enclosed in double quotes (\"). "
        f"CRITICAL RULE FOR SCRIPT TEXT: Inside the massive text dialogue of the 'script' string, you MUST NEVER use any double quotes (\"). If you need to quote something spoken by the hosts, use single quotes (')! "
        f"The JSON must have exactly these keys: "
        f"\"headlines\" (array of top 5 article titles), "
        f"\"script\" (the entire podcast transcript, with absolutely no internal double quotes), and "
        f"\"audio_filename\" (a string formatted exactly as 'news_YYYY-MM-DD.wav' using today's date)."
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

def generate_audio(client, text, filename):
    print(f"Generating audio for {filename}...")
    
    chunks = split_text_into_chunks(text)
    full_audio_bytes = bytearray()
    
    print(f"Divided script into {len(chunks)} chunks for TTS processing.")
    
    for i, chunk in enumerate(chunks):
        if not chunk.strip():
            continue
            
        if i > 0:
            print("Sleeping for 15 seconds to respect Gemini API free-tier TTS rate limits...")
            time.sleep(15)
            
        print(f"Processing chunk {i+1}/{len(chunks)}...")
        # Generate PCM audio bytes utilizing the requested multi-speaker TTS model
        response = client.models.generate_content(
            model='gemini-2.5-flash-preview-tts',
            contents=chunk,
            config=types.GenerateContentConfig(
                response_modalities=["AUDIO"],
                speech_config=types.SpeechConfig(
                    multi_speaker_voice_config=types.MultiSpeakerVoiceConfig(
                        speaker_voice_configs=[
                            types.SpeakerVoiceConfig(
                                speaker="Alex",
                                voice_config=types.VoiceConfig(
                                    prebuilt_voice_config=types.PrebuiltVoiceConfig(
                                        voice_name="Puck"
                                    )
                                )
                            ),
                            types.SpeakerVoiceConfig(
                                speaker="Sam",
                                voice_config=types.VoiceConfig(
                                    prebuilt_voice_config=types.PrebuiltVoiceConfig(
                                        voice_name="Kore"
                                    )
                                )
                            )
                        ]
                    )
                )
            )
        )
        
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
    
    # Save the PCM buffer to a valid WAV file manually
    # Default outputs are mostly 24kHz, 1-channel, 16-bit PCM
    with wave.open(filename, 'wb') as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2) # 16-bit width corresponds to 2 bytes
        wav_file.setframerate(24000)
        wav_file.writeframes(full_audio_bytes)
        
    print(f"Successfully saved {filename}")


def cleanup_old_files():
    now = datetime.now()
    cutoff_date = now - timedelta(days=7)
    wav_files = glob.glob("*.wav")
    for f in wav_files:
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
    topics = get_topics()
    print(f"Topics retrieved: {topics}")
    
    client = get_gemini_client()
    
    # 1. AI Generation
    print("Generating script...")
    podcast_data = generate_script_and_metadata(client, topics)
    print(f"Generated metadata topics array count limits met.")
    
    # 2. Audio Generation
    script_text = podcast_data.get("script", "")
    audio_filename = podcast_data.get("audio_filename")
    
    if script_text and audio_filename:
        generate_audio(client, script_text, audio_filename)
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
