# Apple Silicon M4 Local LLM with Ollama

Apple Silicon Mac に Ollama と拒否傾向を抑えたローカル LLM を導入する `run.sh` です。会話、Webクロール、ブラウザ操作、画像認識、Mac操作、Androidからのリモート利用を1つの入口にまとめています。

## 必要環境

- Apple Silicon Mac（M1 / M2 / M3 / M4）
- macOS 14 Sonoma 以降
- 既定モデル用に 16GB 以上のユニファイドメモリを推奨
- モデルとキャッシュ用の空きディスク容量

## 使い方

### 初回セットアップと起動

新規に取得する場合は、次を Bash で実行します。
`run.sh setup` は Homebrew / Ollama、ローカルモデル、各エージェント、公式Tailscaleをまとめてセットアップします。既定構成のモデルは約15GBです。TailscaleのインストールではmacOSの管理者パスワードが必要です。

```bash
set -Eeuo pipefail

git clone https://github.com/yuusakuri/apple-silicon-m4-ollama.git
cd apple-silicon-m4-ollama
chmod +x run.sh
./run.sh setup
./run.sh start
```
Macで [http://127.0.0.1:8787](http://127.0.0.1:8787) を開きます。既定のベースモデルは `hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M` です。

### セットアップ済みの環境で起動

```bash
./run.sh start
```

### オプション

```bash
# セットアップ後すぐにチャットを開く
./run.sh setup-ai

# モデル取得と作成のみ行う
./run.sh setup-ai --no-chat

# Dolphin 3 をベースモデルにする
./run.sh setup-ai --dolphin

# ベースモデルを直接指定する
./run.sh setup-ai --model dolphin-llama3:8b

# カスタムモデルに別名を付ける
./run.sh setup-ai --custom-name private-dolphin

# Modelfile を使わずベースモデルをそのまま起動
./run.sh setup-ai --base-only

# 32GB 以上の Mac で大きなモデルを試す
./run.sh setup-ai --model dolphin-mixtral:8x7b

# 環境変数でベースモデルを指定
MODEL_NAME=dolphin3:8b ./run.sh setup-ai
```
使えるコマンドは `./run.sh help`、モデルのオプションは `./run.sh setup-ai --help` で確認できます。

### Webクロール、ブラウザ操作、画像認識、Mac操作

Crawl4AI、browser-use、画像認識用の `gemma3:4b`、Mac操作用の `qwen3-vl:8b` を追加する場合は、次を実行します。

```bash
./run.sh setup-agents
```

Webクロール:

```bash
source .agents-venv/bin/activate
crwl https://example.com -o markdown
crwl https://example.com --deep-crawl bfs --max-pages 10 -o markdown
```

ブラウザ操作:

```bash
source .agents-venv/bin/activate
python agents/browser_agent.py \
  'ニュースサイトを開き、今日の主要ニュースを5件まとめて'
```

画像・スクリーンショット認識:

```bash
screencapture -x /tmp/current-screen.png
python agents/vision.py /tmp/current-screen.png \
  '画面に表示されている要素と、次に操作できる候補を箇条書きで返して'
```

Mac操作:

```bash
source .agents-venv/bin/activate
python agents/mac_agent.py \
  'Safari を開き、https://example.com を表示して'
```

### 統合コンソール

会話、クロール、ブラウザ、画像認識、Mac操作を1つのWeb画面から実行します。初回セットアップ後は次の1コマンドで起動できます。

```bash
./run.sh start
```

Macで [http://127.0.0.1:8787](http://127.0.0.1:8787) を開きます。通常の質問はそのまま入力し、次のように先頭へ用途を書くと自動判定します。

```text
クロール https://example.com
ブラウザ https://example.com を開いて内容を要約して
Mac Safari を開いて https://example.com を表示して
```

画像を添付すると画像認識になります。画面の選択メニューから用途を固定することもできます。

### Androidから開く

AndroidからMacの統合コンソールを操作します。初回はローカルエージェントと公式Tailscaleをセットアップします。

```bash
./run.sh setup
```

TailscaleアプリでVPN拡張を許可し、MacとAndroidに同じアカウントでログインしたあと、Macで次を実行します。

```bash
./run.sh remote
```

初回はTailscaleのログインとHTTPS有効化をブラウザで完了します。表示された `https://<Mac名>.<tailnet名>.ts.net` をAndroidのブラウザで開きます。終了する場合はMac側で `Ctrl+C` を押します。

### ログイン時に自動起動

手動で実行中の `./run.sh remote` を `Ctrl+C` で終了してから、次を1回実行します。

```bash
./run.sh enable-autostart
```

AIコンソールはMacへのログイン時に起動し、Tailscale Serveはバックグラウンドで再開します。通常は同じ `https://<Mac名>.<tailnet名>.ts.net` を引き続き使用できます。

自動起動とTailscale Serveを停止する場合:

```bash
./run.sh disable-autostart
```

### API から実行

```bash
curl http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "my-local-llm",
    "messages": [{"role": "user", "content": "こんにちは"}],
    "stream": false
  }'
```

## モデル選択の目安

| モデル | ダウンロードの目安 | メモリの目安 | 用途 |
| --- | ---: | ---: | --- |
| `hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M` | 約 4.92GB | 16GB 以上 | 既定。重み編集によって拒否傾向を抑えた Llama 3.1 8B |
| `dolphin3:8b` | 約 4.9GB | 16GB 以上 | 一般対話、コード、長いコンテキスト |
| `dolphin-llama3:8b` | 約 4.7GB | 16GB 以上 | Dolphin 2.9 / Llama 3 ベース |
| `dolphin-mixtral:8x7b` | 約 26GB | 32GB 以上 | より大きな MoE モデル。余裕のある M4 Pro / Max 向け |
| `dolphin-llama3:70b` | 約 40GB | 64GB 以上推奨 | 高容量 Mac 向け |
| `gemma3:4b` | 約 3.3GB | 8GB 以上 | 統合コンソールの画像認識用 |
| `qwen3-vl:8b` | 約 6.1GB | 16GB 以上 | 統合コンソールのMac操作用 |

## トラブルシューティング

### `brew` が見つからない

Homebrew のインストール完了時に表示される `shellenv` の手順を実行し、新しいターミナルでスクリプトを再実行します。

### Ollama が 60 秒以内に起動しない

```bash
brew services info ollama
tail -n 100 "$(brew --prefix)/var/log/ollama.log"
brew services restart ollama
```

### メモリ不足になる

`dolphin3:8b` または `dolphin-llama3:8b` を選び、他のメモリ使用量が多いアプリを終了してください。コンテキスト長を大きくすると必要メモリも増えます。

### `Connecting the Mac to Tailscale` で止まる

現在の実行を `Ctrl+C` で終了します。システム設定の「一般」→「ログイン項目と機能拡張」→「ネットワーク機能拡張」で情報ボタンを開き、Tailscale Network Extensionをオンにします。Touch IDまたは管理者パスワードで承認し、VPN構成の追加を許可したあと、メニューバーのTailscaleからログインして `./run.sh remote` を再実行します。

## 参考資料

- [Ollama: macOS](https://docs.ollama.com/macos)
- [Hugging Face: Ollama で GGUF を実行](https://huggingface.co/docs/hub/en/ollama)
- [既定のアブリテレーション済み Llama 3.1 8B GGUF](https://huggingface.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF)
- [Ollama: dolphin3](https://ollama.com/library/dolphin3)
- [Ollama: dolphin-llama3](https://ollama.com/library/dolphin-llama3)
- [Ollama: dolphin-mixtral](https://ollama.com/library/dolphin-mixtral)
- [Ollama: gemma3](https://ollama.com/library/gemma3)
- [Ollama: qwen3-vl](https://ollama.com/library/qwen3-vl)
- [Tailscale: macOSへのインストール](https://tailscale.com/docs/install/mac)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
