const { clipboard } = require('electron');
const { exec } = require('child_process');

function inject(text) {
    // Save current clipboard
    const savedText = clipboard.readText();
    
    // Write transcript to clipboard
    clipboard.writeText(text);

    // Wait for clipboard to propagate
    setTimeout(() => {
        // Simulate Ctrl+V using PowerShell
        const powershellCommand = `powershell -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('^v')"`;
        
        exec(powershellCommand, (error) => {
            if (error) {
                console.error('Failed to simulate Ctrl+V:', error);
            }
            
            // Restore original clipboard after a delay
            setTimeout(() => {
                clipboard.writeText(savedText);
            }, 500);
        });
    }, 100);
}

module.exports = { inject };
