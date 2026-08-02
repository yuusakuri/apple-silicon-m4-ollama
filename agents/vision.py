#!/usr/bin/env python3

"""Analyze an image with a local Ollama vision model."""

import argparse
import base64
import json
from pathlib import Path
from urllib.request import Request, urlopen


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze an image with a local Ollama vision model."
    )
    parser.add_argument("image", type=Path, help="Image file to analyze")
    parser.add_argument("prompt", help="Question or instruction for the image")
    parser.add_argument(
        "--model",
        default="gemma3:4b",
        help="Installed Ollama vision model (default: gemma3:4b)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    image = base64.b64encode(args.image.read_bytes()).decode("ascii")
    body = json.dumps(
        {
            "model": args.model,
            "messages": [
                {
                    "role": "user",
                    "content": args.prompt,
                    "images": [image],
                }
            ],
            "stream": False,
            "think": False,
        }
    ).encode("utf-8")
    request = Request(
        "http://127.0.0.1:11434/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=300) as response:
        result = json.load(response)
    message = result["message"]
    print(message["content"] or message.get("thinking", ""))


if __name__ == "__main__":
    main()
