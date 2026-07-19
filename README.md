# Apple Silicon M4 Local LLM with Ollama

Apple Silicon Mac に Ollama と低拒否傾向のローカル LLM を導入する Bash スクリプトです。既定ではアブリテレーション済み Llama 3.1 8B を使い、Dolphin 系モデルにも切り替えられます。処理を関数単位に分け、再実行しても既存の Homebrew / Ollama を再インストールしない構成にしています。

> [!IMPORTANT]
> 「ローカル」は、推論データを外部 API に送らないという意味です。Homebrew、Ollama、モデルの初回ダウンロードにはインターネット接続が必要です。モデルの出力には誤りや不適切な内容が含まれ得るため、利用者が確認してください。

## できること

- macOS 14 以上・Apple Silicon (`arm64`) であることを確認
- Homebrew がなければ公式インストーラーから導入
- Ollama を Homebrew Cask で導入
- Ollama のローカル API が応答するまで待機
- Hugging Face から量子化済みアブリテレーションモデルを直接取得
- `Modelfile` から `my-local-llm` を作成
- 直接的に回答するカスタムシステムプロンプトで対話を開始
- `--dolphin` / `--model` でベースモデル変更、`--base-only` でカスタム作成を省略
- `--no-chat` でモデル作成まで実行

## 必要環境

- Apple Silicon Mac（M1 / M2 / M3 / M4）
- macOS 14 Sonoma 以降
- 既定モデル用に 16GB 以上のユニファイドメモリを推奨
- モデルとキャッシュ用の空きディスク容量

## クイックスタート

```bash
git clone https://github.com/yuusakuri/apple-silicon-m4-ollama.git
cd apple-silicon-m4-ollama
chmod +x setup_ai.sh
./setup_ai.sh
```

既定のベースモデルは `hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M` です。初回は約 4.92GB のモデルデータをダウンロードし、同じモデルデータを再利用する `my-local-llm` を作って起動します。対話を終えるには `/bye` を入力します。

## 使い方

```bash
# セットアップ、モデル取得、チャット開始
./setup_ai.sh

# モデル取得まで行い、チャットは開始しない
./setup_ai.sh --no-chat

# Dolphin 3 をベースにする
./setup_ai.sh --dolphin

# 元の Dolphin Llama 3 8B をベースにする
./setup_ai.sh --model dolphin-llama3:8b

# カスタムモデルに別名を付ける
./setup_ai.sh --custom-name private-dolphin

# Modelfile を使わずベースモデルをそのまま起動
./setup_ai.sh --base-only

# 32GB 以上の Mac で大きなモデルを試す
./setup_ai.sh --model dolphin-mixtral:8x7b

# 環境変数でも指定可能
MODEL_NAME=dolphin3:8b ./setup_ai.sh
```

利用可能なオプションは `./setup_ai.sh --help` で確認できます。

## モデル選択の目安

| モデル | ダウンロードの目安 | メモリの目安 | 用途 |
| --- | ---: | ---: | --- |
| `hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M` | 約 4.92GB | 16GB 以上 | 既定。重み編集によって拒否傾向を抑えた Llama 3.1 8B |
| `dolphin3:8b` | 約 4.9GB | 16GB 以上 | 一般対話、コード、長いコンテキスト |
| `dolphin-llama3:8b` | 約 4.7GB | 16GB 以上 | Dolphin 2.9 / Llama 3 ベース |
| `dolphin-mixtral:8x7b` | 約 26GB | 32GB 以上 | より大きな MoE モデル。余裕のある M4 Pro / Max 向け |
| `dolphin-llama3:70b` | 約 40GB | 64GB 以上推奨 | 高容量 Mac 向け |

実際のメモリ使用量はコンテキスト長などで増えます。メモリの目安は余裕を含めた実用上の推奨で、モデルファイルのサイズと同じではありません。

## アブリテレーションを既定にした理由

アブリテレーションは、拒否するプロンプトと応答するプロンプトの内部表現の差から拒否に関連する方向を推定し、その成分をモデルの重みから抑える手法です。プロンプトだけで口調を変えるより、拒否傾向を下げる効果は直接的です。

このリポジトリでは次のモデルと量子化を明示指定します。

```bash
ollama run hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M
```

この候補を選んだ理由は次のとおりです。

- Hugging Face の Ollama 公式ガイドに実行例として掲載されている
- Llama 3 より新しい Llama 3.1 8B Instruct がベース
- M4 の 16GB 構成でも扱いやすい `Q4_K_M` が明示されている
- モデルページで GGUF ファイルと約 4.92GB のサイズを確認できる

提示された FailSpy 版も次のコマンドで試せます。

```bash
./setup_ai.sh \
  --model hf.co/FailSpy/Meta-Llama-3-8B-Instruct-abliterated-v3-GGUF
```

ただし、アブリテレーションでも拒否がゼロになる保証はありません。FailSpy のモデルカードも、拒否・誤解・倫理的な説教が残る可能性を明記しています。また、重み編集や量子化による品質低下・予期しない癖もあり得ます。「最も確実」は絶対保証ではなく、このリポジトリでは「プロンプトだけに頼るより再現性が高い」という意味です。

## `Modelfile` で応答スタイルをさらに調整する

Dolphin やアブリテレーション済みモデルでも、質問や会話履歴によっては拒否的な応答を返します。生成は確率的であり、ファインチューニング、重み編集、プロンプトテンプレート、システムメッセージなど複数の要素が結果に影響するためです。

このリポジトリの [`Modelfile`](Modelfile) は、回答を直接的・具体的にし、不必要な説教や定型的な前置きを避けるよう指示します。`setup_ai.sh` は選択したベースモデルに `FROM` を自動で合わせ、`my-local-llm` を作ります。ベースのモデルデータを再利用するため、同じ重みをもう一度ダウンロードする必要はありません。

手動で作成する場合は次のとおりです。

```bash
ollama pull hf.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF:Q4_K_M
ollama create my-local-llm -f Modelfile
ollama run my-local-llm
```

`Modelfile` の `SYSTEM` はモデルに渡すシステムメッセージであり、「絶対的なルール」ではありません。拒否を完全に消す保証はなく、`SYSTEM "."` のように内容を空同然にしても同様です。期待する口調や応答例を具体的に書き、実際の用途で評価してください。

## 手動実行

セットアップ済みなら次のコマンドだけで起動できます。

```bash
ollama run my-local-llm
```

Ollama の API は標準ではローカルの `http://127.0.0.1:11434` で利用できます。

```bash
curl http://127.0.0.1:11434/api/chat \
  -d '{
    "model": "my-local-llm",
    "messages": [{"role": "user", "content": "こんにちは"}],
    "stream": false
  }'
```

## セキュリティと責任ある利用

- Dolphin は強い指示追従性を意図したモデルです。「無検閲」は、正確性・合法性・安全性を保証する言葉ではありません。
- 出力を医療・法律・金融・セキュリティなどの重要判断にそのまま使わないでください。
- 機密データを扱う場合は、Ollama の待受アドレスを外部公開していないことも確認してください。
- モデルごとのライセンスと、利用地域の法令・組織の規則に従ってください。

## トラブルシューティング

### `brew` が見つからない

Homebrew のインストール完了時に表示される `shellenv` の手順を実行し、新しいターミナルでスクリプトを再実行します。

### Ollama が 60 秒以内に起動しない

Ollama アプリを一度手動で開き、macOS の確認ダイアログに応答してください。ログは `~/.ollama/logs/server.log` にあります。

### メモリ不足になる

`dolphin3:8b` または `dolphin-llama3:8b` を選び、他のメモリ使用量が多いアプリを終了してください。コンテキスト長を大きくすると必要メモリも増えます。

## 開発時の確認

```bash
bash -n setup_ai.sh
shellcheck setup_ai.sh
```

## 参考資料

- [Ollama: macOS](https://docs.ollama.com/macos)
- [Ollama: Modelfile reference](https://docs.ollama.com/modelfile)
- [Hugging Face: Ollama で GGUF を実行](https://huggingface.co/docs/hub/en/ollama)
- [既定のアブリテレーション済み Llama 3.1 8B GGUF](https://huggingface.co/mlabonne/Meta-Llama-3.1-8B-Instruct-abliterated-GGUF)
- [FailSpy の Llama 3 8B abliterated v3 GGUF](https://huggingface.co/FailSpy/Meta-Llama-3-8B-Instruct-abliterated-v3-GGUF)
- [Ollama: dolphin3](https://ollama.com/library/dolphin3)
- [Ollama: dolphin-llama3](https://ollama.com/library/dolphin-llama3)
- [Ollama: dolphin-mixtral](https://ollama.com/library/dolphin-mixtral)

## License

このリポジトリのスクリプトとドキュメントは [MIT License](LICENSE) で公開しています。各モデルには別のライセンスが適用されます。
