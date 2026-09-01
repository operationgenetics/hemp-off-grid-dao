#!/usr/bin/env bash
set -e

echo "==> Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash

# Make sure the install path is on PATH for this session
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"

echo "==> Verifying install..."
opencode --version

# If you already have a Zen API key, export it before running this script:
#   export OPENCODE_ZEN_API_KEY="sk-zen-xxxxxxxxxxxx"
if [ -z "$OPENCODE_ZEN_API_KEY" ]; then
  echo "==> No OPENCODE_ZEN_API_KEY found in environment."
  echo "    Run 'opencode auth login' manually and pick 'OpenCode Zen' to sign in interactively,"
  echo "    or re-run this script with: OPENCODE_ZEN_API_KEY=sk-zen-xxxx ./setup-opencode.sh"
fi

echo "==> Writing opencode.json..."
cat > opencode.json << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/mimo-v2.5-free",
  "provider": {
    "opencode": {
      "options": {
        "apiKey": "{env:OPENCODE_ZEN_API_KEY}"
      }
    }
  }
}
EOF

echo "==> Committing config..."
git add opencode.json
git commit -m "Configure OpenCode with MiMo-V2.5 Free" || echo "Nothing to commit (maybe already committed)."

echo "==> Done. Run 'opencode' to launch, then '/models' to confirm MiMo-V2.5 Free is active."
