import os
import json
import base64
import wave
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
        f"Generate a daily news podcast. Provide exactly 3 fields in JSON format: "
        f"'headlines' (array of top 5 article titles), "
        f"'script' (a conversational 10-minute podcast script detailing the news), and "
        f"'audio_filename' (a string formatted exactly as 'news_YYYY-MM-DD.wav' using today's date)."
    )
    
    response = client.models.generate_content(
        model='gemini-2.5-flash',
        contents=prompt,
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            tools=[{"google_search": {}}],
            temperature=0.7
        )
    )
    
    try:
        content = json.loads(response.text)
        
        # Ensure correct extension fallback in case LLM generates a different one
        filename = content.get("audio_filename", f"news_{datetime.now().strftime('%Y-%m-%d')}.wav")
        if filename.endswith(".mp3"):
            filename = filename.replace(".mp3", ".wav")
        if not filename.endswith(".wav"):
            filename += ".wav"
            
        content["audio_filename"] = filename
        return content
    except json.JSONDecodeError as e:
        raise ValueError("Failed to parse JSON from Gemini") from e

def generate_audio(client, text, filename):
    print(f"Generating audio for {filename}...")
    
    # Generate PCM audio bytes utilizing the requested TTS model
    response = client.models.generate_content(
        model='gemini-2.5-flash-preview-tts',
        contents=text
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
    
    if not pcm_data:
        raise RuntimeError("Failed to extract PCM audio data from Gemini response")
    
    # Save the PCM buffer to a valid WAV file manually
    # Default outputs are mostly 24kHz, 1-channel, 16-bit PCM
    with wave.open(filename, 'wb') as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2) # 16-bit width corresponds to 2 bytes
        wav_file.setframerate(24000)
        wav_file.writeframes(pcm_data)
        
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
