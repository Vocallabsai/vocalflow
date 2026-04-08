#!/usr/bin/env bash
pkill -x VocalFlow 2>/dev/null || true
sleep 0.3
open VocalFlow.app
echo "VocalFlow launched. If hotkey doesn't work, re-toggle in:"
echo "  System Settings → Privacy & Security → Accessibility"
