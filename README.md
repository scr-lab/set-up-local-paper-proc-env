# lab-notebook — ローカル論文処理環境セットアップ

> **Open Notebook + Ollama** で構築する、プライバシー安全な NotebookLM 代替環境。  
> **`git clone` → `setup.ps1` の 1 コマンドで構築完了します。**

---

## 必要なもの（事前準備不要、スクリプトが自動インストール）

| 依存 | 備考 |
|------|------|
| Windows 10 20H1 以降 / Windows 11 | 必須 |
| PowerShell 5.0 以降 | 標準搭載 |
| winget（アプリ インストーラー） | Microsoft Store から更新 |
| GPU（推奨） | VRAM 8 GB 以上推奨 |

---

## クイックスタート

```powershell
# 1. リポジトリをクローン
git clone https://github.com/<your-org>/lab-notebook.git
cd lab-notebook

# 2. セットアップを実行（管理者権限が必要です）
# 右クリック → "PowerShell を管理者として実行" で実行するか:
Start-Process powershell -Verb RunAs -ArgumentList "-File .\setup.ps1"

# 3. ブラウザで開く（スクリプト完了後に自動で開きます）
# http://localhost:8502
```

> **初回はモデルのダウンロード（数 GB）があるため、10〜30 分程度かかります。**

---

## ⚙️ オプション

```powershell
# VRAM に合わせてモデルを変更
.\setup.ps1 -Model gemma3:12b        # VRAM 12 GB 以上
.\setup.ps1 -Model gemma3:1b         # VRAM 4 GB 以下（動作確認用）
.\setup.ps1 -Model llama3.1:8b-instruct-q4_K_M  # 量子化版（省メモリ）

# Docker または Ollama がすでにインストール済みの場合
.\setup.ps1 -SkipDocker
.\setup.ps1 -SkipOllama

# 対話なし（CI・自動実行用）
.\setup.ps1 -Unattended

# インストール先を変更（デフォルト: $HOME\open-notebook）
.\setup.ps1 -InstallDir "D:\lab-notebook"
```

---

## Open Notebook の初期設定（セットアップ後）

`http://localhost:8502` をブラウザで開き、以下を設定します。

1. 左ペイン → **モデル** → Ollama の **「+ 設定を追加」**
   - 設定名: 任意（例: `Ollama Local`）
   - ベース URL: `http://host.docker.internal:11434`
   - API キー: 不要

2. **Language モデル** を `llama3.1:8b`（または選択したモデル）に設定

3. **Embedding モデル** を `nomic-embed-text:latest` に設定

4. 左ペイン → **新規** から論文 PDF をアップロード 🎉

---

## プロンプトテンプレート

`prompts/templates.toml` に論文処理用のテンプレートが収録されています。

| テンプレート | 用途 |
|------------|------|
| `basic_summary` | 問題設定・手法・結果の 5 項目要約 |
| `method_detail` | 手法の詳細（アーキテクチャ・学習手順） |
| `related_work` | 引用論文との比較分析 |
| `reproduce_checklist` | 再現実装チェックリスト |
| `critical_review` | 査読者視点の批判的評価 |
| `seminar_slides` | ゼミ発表用箇条書きサマリー |
| `cross_comparison` | 複数論文の横断比較表 |
| `future_research` | 次の研究アイデア発散 |

---

## arXiv 自動取り込み

```powershell
cd $HOME\open-notebook

# 動作確認（取得のみ、Open Notebook へは送信しない）
python arxiv_fetcher.py --dry-run

# 実際に取り込み
python arxiv_fetcher.py

# 毎日 08:00 に自動実行
python arxiv_fetcher.py --schedule
```

### 検索クエリのカスタマイズ

`arxiv_fetcher.py` の `SEARCH_QUERIES` リストを編集してください。

```python
SEARCH_QUERIES = [
    ("ti:transformer AND cat:cs.LG", 5, "Transformer"),
    ("au:Hinton_G",                  3, "Hinton"),
    ("abs:contrastive learning",     5, "ContrastiveLearning"),
]
```

[arXiv 検索構文リファレンス](https://arxiv.org/help/api/user-manual#query_details)

---

## 日常的な操作

```powershell
# 起動（Docker Desktop を起動後に実行）
cd $HOME\open-notebook && docker compose up -d

# 停止
cd $HOME\open-notebook && docker compose stop

# ログ確認
cd $HOME\open-notebook && docker compose logs open_notebook

# イメージの更新
cd $HOME\open-notebook && docker compose pull && docker compose up -d
```

---

## トラブルシューティング

### Open Notebook の画面が真っ白

```powershell
cd $HOME\open-notebook
docker compose restart
```

解消しない場合は PC を再起動してください。

### チャットが固まる / 応答が遅い

大きなモデルは推論に 30 秒以上かかることがあります。ブラウザをリロードすると応答が表示されます。  
軽量モデル `gemma3:1b` への変更も効果的です。

### スキャン PDF が Processing... のまま

```powershell
pip install ocrmypdf
ocrmypdf input.pdf output_ocr.pdf --language jpn+eng
```

### VRAM 不足

```powershell
ollama pull llama3.1:8b-instruct-q4_K_M
```

---

## リポジトリ構成

```
lab-notebook/
├── setup.ps1               ← メインセットアップスクリプト
├── scripts/
│   └── arxiv_fetcher.py    ← arXiv 自動取り込みスクリプト
├── prompts/
│   └── templates.toml      ← 論文処理プロンプトテンプレート集
├── docs/
│   └── setup-guide.md      ← 詳細ドキュメント（Zola 向け）
└── README.md               ← このファイル
```

---

## ライセンス

MIT License

---

## 謝辞

- [Open Notebook](https://github.com/lfnovo/open-notebook)
- [Ollama](https://github.com/ollama/ollama)
- [roswell さんの Zenn 記事](https://zenn.dev/roswell/articles/open-notebook-setup)
