#!/usr/bin/env python3

"""One local web console for Ollama chat, crawl, browser, vision, and Mac tasks."""

import asyncio
import json
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.request import Request, urlopen

from fastapi import FastAPI, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import HTMLResponse

ROOT = Path(__file__).resolve().parent.parent
PYTHON = ROOT / ".agents-venv" / "bin" / "python"
OLLAMA_CHAT_URL = "http://127.0.0.1:11434/api/chat"
URL_PATTERN = re.compile(r"https?://[^\s]+")
TASK_LOCK = asyncio.Lock()

app = FastAPI(title="Local Agent Console", docs_url=None, redoc_url=None)


def classify(task: str, has_image: bool) -> str:
    if has_image:
        return "vision"
    lowered = task.lower().strip()
    if lowered.startswith(("crawl ", "クロール ")):
        return "crawl"
    if lowered.startswith(("browser ", "ブラウザ ")):
        return "browser"
    if lowered.startswith(("mac ", "macを", "pc ", "pcを", "パソコン")):
        return "mac"
    return "chat"


def run(command: list[str], timeout: int) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )
    return completed.stdout.strip() or "(出力なし)"


def chat(task: str) -> str:
    body = {
        "model": "my-local-llm",
        "messages": [{"role": "user", "content": task}],
        "stream": False,
    }
    request = Request(
        OLLAMA_CHAT_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=300) as response:
        result = json.load(response)
    return result["message"]["content"]


def crawl(task: str) -> str:
    match = URL_PATTERN.search(task)
    if not match:
        raise ValueError("クロールする URL を入力してください。")
    return run(
        [str(ROOT / ".agents-venv/bin/crwl"), match.group(), "-o", "markdown"],
        timeout=300,
    )


def browser(task: str) -> str:
    cleaned = re.sub(r"^(browser|ブラウザ)\s*", "", task, flags=re.IGNORECASE)
    return run([str(PYTHON), "agents/browser_agent.py", cleaned], timeout=600)


def mac(task: str) -> str:
    cleaned = re.sub(r"^(mac|pc|パソコン)\s*", "", task, flags=re.IGNORECASE)
    return run([str(PYTHON), "agents/mac_agent.py", cleaned], timeout=900)


def vision(task: str, image: UploadFile) -> str:
    suffix = Path(image.filename or "image.png").suffix or ".png"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as temporary:
        temporary.write(image.file.read())
        image_path = Path(temporary.name)
    try:
        return run([str(PYTHON), "agents/vision.py", str(image_path), task], timeout=300)
    finally:
        image_path.unlink(missing_ok=True)


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return PAGE


@app.get("/favicon.ico", include_in_schema=False)
def favicon() -> Response:
    return Response(status_code=204)


@app.post("/api/run")
async def execute(
    task: str = Form(...),
    mode: str = Form("auto"),
    image: UploadFile | None = File(None),
) -> dict[str, str]:
    if not task.strip():
        raise HTTPException(status_code=400, detail="指示を入力してください。")
    selected = classify(task, image is not None) if mode == "auto" else mode
    try:
        async with TASK_LOCK:
            if selected == "chat":
                output = await asyncio.to_thread(chat, task)
            elif selected == "crawl":
                output = await asyncio.to_thread(crawl, task)
            elif selected == "browser":
                output = await asyncio.to_thread(browser, task)
            elif selected == "mac":
                output = await asyncio.to_thread(mac, task)
            elif selected == "vision" and image is not None:
                output = await asyncio.to_thread(vision, task, image)
            else:
                raise ValueError("画像認識には画像ファイルを添付してください。")
        return {"mode": selected, "output": output}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="処理が時間切れになりました。") from None
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error


PAGE = """<!doctype html>
<html lang=\"ja\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>Local Agent Console</title>
<style>
body{margin:0;background:#101216;color:#e8eaed;font:16px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:820px;margin:auto;padding:32px 18px}h1{font-size:24px;margin:0 0 6px}.sub{color:#9aa0a6;margin:0 0 24px}textarea,select,input,button{font:inherit}textarea{box-sizing:border-box;width:100%;min-height:150px;background:#1b1f26;border:1px solid #343a46;border-radius:12px;color:inherit;padding:14px;resize:vertical}.row{display:flex;gap:10px;margin:12px 0;flex-wrap:wrap}select,input{background:#1b1f26;color:inherit;border:1px solid #343a46;border-radius:8px;padding:9px}button{border:0;border-radius:9px;background:#76a7ff;color:#071425;font-weight:700;padding:10px 18px;cursor:pointer}button:disabled{opacity:.55}pre{min-height:100px;white-space:pre-wrap;word-break:break-word;background:#161a20;border:1px solid #2a303a;border-radius:12px;padding:14px}.hint{color:#9aa0a6;font-size:13px}.tag{font-weight:700;color:#76a7ff}</style>
<main><h1>Local Agent Console</h1><p class=\"sub\">Ollama / クロール / ブラウザ / 画像 / Mac を1つの入力欄から実行</p>
<form id=\"form\"><textarea name=\"task\" placeholder=\"例: クロール https://example.com\n例: ブラウザ https://example.com を開いて要約して\n例: Mac Safari を開いて example.com を表示して\n通常の質問はそのまま入力\"></textarea><div class=\"row\"><select name=\"mode\"><option value=\"auto\">自動判定</option><option value=\"chat\">会話</option><option value=\"crawl\">クロール</option><option value=\"browser\">ブラウザ</option><option value=\"vision\">画像認識</option><option value=\"mac\">Mac操作</option></select><input type=\"file\" name=\"image\" accept=\"image/*\"><button>実行</button></div></form><p class=\"hint\">画像を添付すると画像認識になります。処理中は次の指示を待ち行列に入れます。</p><p class=\"tag\" id=\"mode\"></p><pre id=\"output\">結果はここに表示されます。</pre></main>
<script>const f=document.querySelector('#form'),o=document.querySelector('#output'),m=document.querySelector('#mode'),b=f.querySelector('button');f.onsubmit=async e=>{e.preventDefault();b.disabled=true;o.textContent='実行中…';m.textContent='';try{const r=await fetch('/api/run',{method:'POST',body:new FormData(f)}),d=await r.json();if(!r.ok)throw Error(d.detail);m.textContent='実行モード: '+d.mode;o.textContent=d.output}catch(e){o.textContent='Error: '+e.message}finally{b.disabled=false}};</script></html>"""
