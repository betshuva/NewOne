import os

import anthropic

client = anthropic.Anthropic(
    api_key=os.getenv("ANTHROPIC_API_KEY", ""),
)

try:
    # Faster auth check: lightweight metadata request instead of full generation.
    client.models.list(limit=1)
    print("Authentication Successful!")
except anthropic.AuthenticationError:
    print("Authentication Failed: Check your API Key.")
