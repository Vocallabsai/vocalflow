module.exports = {
  // Required core transcription provider API Key
  DEEPGRAM_API_KEY: "",
  
  // Optional NLP processing API Key
  GROQ_API_KEY: "",
  
  // Audio to text defaults
  DEEPGRAM_MODEL: "nova-3",
  DEEPGRAM_LANGUAGE: "en",
  
  // Text optimization defaults
  GROQ_ENABLE: false,
  GROQ_MODEL: "llama3-8b-8192",
  GROQ_SPELLING_CORRECTION: true,
  GROQ_GRAMMAR_CORRECTION: true,
  GROQ_TRANSLITERATION: false,
  GROQ_TRANSLATION: false,
  GROQ_TRANSLITERATION_PAIR: "Hinglish → English",
  GROQ_TRANSLATION_TARGET: "English",
  
  // Default Global Hotkey Activation Trigger
  HOTKEY: "RIGHT ALT"
};
