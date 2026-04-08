const fetch = require('node-fetch');

async function processText(text, options, apiKey, model) {
    if (!apiKey || !model || (!options.fixSpelling && !options.fixGrammar && !options.codeMix && !options.targetLanguage)) {
        return text;
    }

    let instructions = [];
    let stepNumber = 1;

    if (options.codeMix) {
        instructions.push(`${stepNumber}. The input is in ${options.codeMix}. Transliterate any non-Roman script (such as Devanagari, Tamil, etc.) to Roman script. Keep English words as-is. Do not translate — preserve the original meaning in mixed form.`);
        stepNumber++;
    }
    if (options.fixSpelling) {
        instructions.push(`${stepNumber}. Fix any spelling mistakes. Do not change meaning or structure.`);
        stepNumber++;
    }
    if (options.fixGrammar) {
        instructions.push(`${stepNumber}. Fix any grammar mistakes. Do not change meaning or add content.`);
        stepNumber++;
    }
    if (options.targetLanguage) {
        const codeMixStyles = ['Hinglish', 'Tanglish', 'Benglish', 'Kanglish', 'Tenglish', 'Minglish', 'Punglish', 'Spanglish', 'Franglais', 'Portuñol', 'Chinglish', 'Japlish', 'Konglish', 'Arabizi', 'Sheng', 'Camfranglais'];
        if (codeMixStyles.includes(options.targetLanguage)) {
            instructions.push(`${stepNumber}. Rewrite the text in ${options.targetLanguage} style: keep English words as-is, and transliterate any non-Roman script (such as Devanagari, Tamil, etc.) to Roman script. Do not translate — preserve the original meaning in mixed form.`);
        } else {
            instructions.push(`${stepNumber}. Translate the entire text to ${options.targetLanguage}. Every word must be in ${options.targetLanguage}.`);
        }
    }

    const systemPrompt = `Process the following text by applying these steps in order:\n${instructions.join('\n')}\nReturn only the final processed text with no explanation.`;

    try {
        const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${apiKey}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                model: model,
                messages: [
                    { role: 'system', content: systemPrompt },
                    { role: 'user', content: text }
                ],
                temperature: 0
            })
        });

        const data = await response.json();
        return data.choices?.[0]?.message?.content || text;
    } catch (err) {
        console.error('Failed to process text via Groq:', err);
        return text;
    }
}

async function fetchGroqModels(apiKey) {
    try {
        const response = await fetch('https://api.groq.com/openai/v1/models', {
            headers: { 'Authorization': `Bearer ${apiKey}` }
        });
        const data = await response.json();
        return (data.data || [])
            .filter(m => m.object === 'model')
            .map(m => ({ id: m.id, displayName: m.id }))
            .sort((a, b) => a.id.localeCompare(b.id));
    } catch (err) {
        console.error('Failed to fetch Groq models:', err);
        return [];
    }
}

module.exports = { processText, fetchGroqModels };
