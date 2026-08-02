#!/usr/bin/env python3

"""Operate macOS with a local Ollama model and a shell tool loop."""

import argparse
import json
import os
import subprocess
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
OLLAMA_CHAT_URL = "http://127.0.0.1:11434/api/chat"
SYSTEM_PROMPT = """You operate this macOS computer for the user.
Use the shell tool to complete the requested task. You may run shell commands,
AppleScript through osascript, and macOS commands such as open and screencapture.
Inspect command output when needed. Use non-interactive commands. When the task is
complete, respond with a concise result instead of calling another tool. Do not
output your reasoning."""
SHELL_TOOL = {
    "type": "function",
    "function": {
        "name": "shell",
        "description": "Run a zsh command on this Mac and return its combined output.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The zsh command to run.",
                }
            },
            "required": ["command"],
        },
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Operate macOS with a local model.")
    parser.add_argument("task", help="What to do on this Mac")
    parser.add_argument(
        "--model",
        default=os.environ.get("MAC_MODEL", "qwen3-vl:8b"),
        help="Installed Ollama tool model (default: qwen3-vl:8b)",
    )
    parser.add_argument("--max-steps", type=int, default=10)
    return parser.parse_args()


def ask_model(model: str, messages: list[dict]) -> dict:
    body = json.dumps(
        {
            "model": model,
            "messages": messages,
            "tools": [SHELL_TOOL],
            "stream": False,
            "think": False,
            "options": {"num_ctx": 4096, "num_predict": 512, "temperature": 0.2},
        }
    ).encode("utf-8")
    request = Request(
        OLLAMA_CHAT_URL,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=300) as response:
        return json.load(response)["message"]


def run_shell(command: str) -> str:
    completed = subprocess.run(
        ["/bin/zsh", "-lc", command],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
        check=False,
    )
    output = completed.stdout.strip()
    return f"exit_code={completed.returncode}\n{output or '(no output)'}"[-12000:]


def main() -> None:
    args = parse_args()
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"{args.task}\n/no_think"},
    ]
    last_result = ""

    for _ in range(args.max_steps):
        message = ask_model(args.model, messages)
        messages.append(message)
        tool_calls = message.get("tool_calls", [])
        if not tool_calls:
            print(message.get("content", "") or last_result or "Task completed.")
            return

        for tool_call in tool_calls:
            function = tool_call.get("function", {})
            if function.get("name") != "shell":
                result = "Unsupported tool."
            else:
                result = run_shell(function.get("arguments", {}).get("command", ""))
            last_result = result
            messages.append(
                {"role": "tool", "tool_name": function.get("name", "shell"), "content": result}
            )

    raise RuntimeError(f"The task did not finish within {args.max_steps} steps.")


if __name__ == "__main__":
    main()
