#!/usr/bin/env python3

"""Run a Browser Use agent with a local Ollama model."""

import argparse
import asyncio

from browser_use import Agent, BrowserProfile, ChatOllama


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Control a browser with a local Ollama model."
    )
    parser.add_argument("task", help="What the browser agent should do")
    parser.add_argument(
        "--model",
        default="my-local-llm",
        help="Installed Ollama model to use (default: my-local-llm)",
    )
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    agent = Agent(
        task=args.task,
        llm=ChatOllama(model=args.model),
        browser_profile=BrowserProfile(headless=True),
        use_vision=False,
        use_thinking=False,
    )
    history = await agent.run()
    print(history.final_result())


if __name__ == "__main__":
    asyncio.run(main())
