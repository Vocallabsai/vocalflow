const https = require('https');

function makeHttpsRequest(options) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        resolve({
          statusCode: res.statusCode,
          data: data
        });
      });
    });
    
    req.on('error', (err) => {
      reject(err);
    });
    
    req.end();
  });
}

async function fetchDeepgramBalance(apiKey) {
  if (!apiKey) {
    return { ok: false, error: "No API key provided" };
  }

  try {
    // Step 1: Fetch Projects
    const projectsOptions = {
      hostname: 'api.deepgram.com',
      path: '/v1/projects',
      method: 'GET',
      headers: {
        'Authorization': `Token ${apiKey}`,
        'Content-Type': 'application/json'
      }
    };

    const projectsRes = await makeHttpsRequest(projectsOptions);
    if (projectsRes.statusCode !== 200) {
      return { ok: false, error: `Projects API Error: ${projectsRes.statusCode} - ${projectsRes.data}` };
    }

    const projectsData = JSON.parse(projectsRes.data);
    const projects = projectsData.projects || [];
    if (projects.length === 0) {
      return { ok: false, error: "No Deepgram projects found for this key" };
    }

    const firstProject = projects[0];
    const projectId = firstProject.project_id;
    const projectName = firstProject.name || "Default Project";

    // Step 2: Fetch Balances
    const balancesOptions = {
      hostname: 'api.deepgram.com',
      path: `/v1/projects/${projectId}/balances`,
      method: 'GET',
      headers: {
        'Authorization': `Token ${apiKey}`,
        'Content-Type': 'application/json'
      }
    };

    const balancesRes = await makeHttpsRequest(balancesOptions);
    if (balancesRes.statusCode !== 200) {
      return { ok: false, error: `Balances API Error: ${balancesRes.statusCode} - ${balancesRes.data}` };
    }

    const balancesData = JSON.parse(balancesRes.data);
    const balances = balancesData.balances || [];
    
    if (balances.length === 0) {
      return { ok: true, formatted: "$0.0000 USD", projectName, amount: 0, units: "USD" };
    }

    const activeBalance = balances[0];
    const amount = activeBalance.amount || 0;
    const units = activeBalance.units || "USD";
    
    // Format to 4 decimal places commonly used by Deepgram
    const formattedAmount = Number(amount).toFixed(4);
    const formatted = `$${formattedAmount} ${units.toUpperCase()}`;

    return {
      ok: true,
      formatted,
      projectName,
      amount,
      units
    };

  } catch (err) {
    return { ok: false, error: err.message };
  }
}

async function fetchGroqStatus(apiKey) {
  if (!apiKey) {
    return { ok: false, valid: false, status: "✗ No API key provided" };
  }

  try {
    const options = {
      hostname: 'api.groq.com',
      path: '/openai/v1/models',
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json'
      }
    };

    const res = await makeHttpsRequest(options);

    if (res.statusCode === 200) {
      return { 
        ok: true, 
        valid: true, 
        status: "✓ Key valid", 
        note: "Groq has no public balance API — view usage at console.groq.com" 
      };
    } else if (res.statusCode === 401) {
      return { 
        ok: false, 
        valid: false, 
        status: "✗ Invalid or expired key" 
      };
    } else {
      return {
        ok: false,
        valid: false,
        status: `✗ API Error: ${res.statusCode}`
      };
    }
  } catch (err) {
    return { ok: false, valid: false, status: `✗ Request failed: ${err.message}` };
  }
}

module.exports = {
  fetchDeepgramBalance,
  fetchGroqStatus
};
