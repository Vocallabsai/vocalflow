const fetch = require('node-fetch');

async function fetchDeepgramBalance(apiKey) {
    console.log('Fetching Deepgram balance...');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000); // 30s timeout

    try {
        // Step 1: Get projects
        const projectsResponse = await fetch('https://api.deepgram.com/v1/projects', {
            headers: { 'Authorization': `Token ${apiKey}` },
            signal: controller.signal
        });
        
        if (!projectsResponse.ok) {
            const errBody = await projectsResponse.text();
            console.error(`Deepgram projects API error (${projectsResponse.status}):`, errBody);
            return null;
        }

        const projectsData = await projectsResponse.json();
        console.log(`Found ${projectsData.projects ? projectsData.projects.length : 0} projects`);
        
        if (!projectsData.projects || projectsData.projects.length === 0) {
            console.error('No projects found under this Deepgram API key.');
            return null;
        }

        // Search for a project with an active balance
        for (const project of projectsData.projects) {
            try {
                const balanceResponse = await fetch(`https://api.deepgram.com/v1/projects/${project.project_id}/balances`, {
                    headers: { 'Authorization': `Token ${apiKey}` },
                    signal: controller.signal
                });
                
                if (!balanceResponse.ok) continue;
                
                const balanceData = await balanceResponse.json();
                if (balanceData.balances && balanceData.balances.length > 0) {
                    console.log(`Found balance in project: ${project.name}`);
                    return {
                        amount: balanceData.balances[0].amount,
                        currency: balanceData.balances[0].currency || 'USD'
                    };
                }
            } catch (e) {
                console.error(`Error fetching balance for project ${project.project_id}:`, e);
            }
        }
        
        // If no balances found, return 0
        return { amount: 0, currency: 'USD' };
    } catch (err) {
        if (err.name === 'AbortError') {
            console.error('Deepgram balance fetch timed out.');
        } else {
            console.error('Failed to fetch Deepgram balance:', err);
        }
        return null;
    } finally {
        clearTimeout(timeout);
    }
}

module.exports = { fetchDeepgramBalance };
