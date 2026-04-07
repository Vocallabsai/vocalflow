const https = require('https');

async function fetchDeepgramBalance(key) {
    return new Promise((resolve) => {
        if (!key) return resolve(null);
        
        const options = {
            hostname: 'api.deepgram.com',
            path: '/v1/balances',
            method: 'GET',
            headers: {
                'Authorization': `Token ${key}`
            }
        };

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(data);
                    // Extract balance amount dynamically
                    if (parsed.balances && parsed.balances.length > 0) {
                        resolve(parsed.balances[0].amount);
                    } else {
                        resolve(null);
                    }
                } catch (e) {
                    resolve(null);
                }
            });
        });

        req.on('error', () => resolve(null));
        req.end();
    });
}

async function fetchGroqStatus(key) {
    return new Promise((resolve) => {
        if (!key) return resolve(false);

        const options = {
            hostname: 'api.groq.com',
            path: '/openai/v1/models',
            method: 'GET',
            headers: {
                'Authorization': `Bearer ${key}`
            }
        };

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    resolve(true); // Token securely validated against endpoints
                } else {
                    resolve(false);
                }
            });
        });

        req.on('error', () => resolve(false));
        req.end();
    });
}

module.exports = {
    fetchDeepgramBalance,
    fetchGroqStatus
};
