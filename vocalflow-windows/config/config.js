// config/config.js
const config = {
  DEEPGRAM_API_KEY: "YOUR_DEEPGRAM_API_KEY_HERE",
  GROQ_API_KEY: "YOUR_GROQ_API_KEY_HERE",
  DEEPGRAM_MODEL: "nova-2",
  DEEPGRAM_LANGUAGE: "en",
  DEEPGRAM_BASE_URL: "https://api.deepgram.com",
  GROQ_MODEL: "llama3-8b-8192",
  GROQ_BASE_URL: "https://api.groq.com/openai/v1",
  HOTKEY: "RIGHT ALT",
  GROQ_SPELLING_CORRECTION: false,
  GROQ_GRAMMAR_CORRECTION: false,
  GROQ_TRANSLITERATION: false,
  GROQ_TRANSLITERATION_PAIR: "Hinglish → English",
  GROQ_TRANSLATION: false,
  GROQ_TRANSLATION_TARGET: "",
};
module.exports = config;
