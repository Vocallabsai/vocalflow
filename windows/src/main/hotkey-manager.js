const { GlobalKeyboardListener } = require("node-global-key-listener");
const v = new GlobalKeyboardListener();

function startListening(appState, onRecordStart, onRecordEnd) {
    let triggerKeyIsDown = false;

    v.addListener(function (e, down) {
        const name = e.name.toUpperCase();
        const selected = (appState.get('selectedHotkey') || 'RIGHT_ALT').toUpperCase().replace(/_/g, ' ');

        if (name.includes(selected) || name.includes(selected.replace(/ /g, '_'))) {
            if (e.state === "DOWN") {
                if (!triggerKeyIsDown) {
                    triggerKeyIsDown = true;
                    console.log('Hotkey pressed:', name);
                    onRecordStart();
                }
            } else if (e.state === "UP") {
                if (triggerKeyIsDown) {
                    triggerKeyIsDown = false;
                    console.log('Hotkey released:', name);
                    onRecordEnd();
                }
            }
        }
    });
}

module.exports = { startListening };
