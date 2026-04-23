"""
arxiv_fetcher.py  ─  arXiv → Open Notebook 自動取り込みスクリプト
────────────────────────────────────────────────────────────────────
使い方:
  python arxiv_fetcher.py                  # 1 回実行
  python arxiv_fetcher.py --schedule       # 毎日 08:00 に定期実行
  python arxiv_fetcher.py --dry-run        # 取得のみ（Open Notebook へ送信しない）
  python arxiv_fetcher.py --config custom.toml  # 設定ファイルを指定

設定は QUERIES リストを直接編集するか、config.toml で管理できます。
"""

import arxiv
import requests
import json
import argparse
import schedule
import time
import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ─────────────────────────── ユーザー設定エリア ───────────────────────────
# ここを編集して自分の研究テーマに合わせてください

SEARCH_QUERIES = [
    # ── フォーマット: (クエリ文字列, 最大取得件数, ラベル) ──
    # arXiv 検索構文: https://arxiv.org/help/api/user-manual#query_details

    # 例1: タイトルにキーワードを含む論文
    ("ti:diffusion model AND cat:cs.CV",       5, "Vision Diffusion"),

    # 例2: LLM 関連 (CS.CL)
    ("ti:large language model AND cat:cs.CL",  5, "LLM"),

    # 例3: RAG 全カテゴリ
    ("abs:retrieval augmented generation",     3, "RAG"),

    # 例4: 特定著者
    # ("au:LeCun_Y", 3, "LeCun"),

    # 例5: 材料科学 × ML
    # ("ti:machine learning AND cat:cond-mat.mtrl-sci", 3, "MatML"),

    # 例6: タンパク質構造
    # ("ti:protein structure AND cat:q-bio.BM", 3, "BioStruct"),
]

# 過去何日分を取得するか（毎日 1 回実行なら 1 が適切）
SINCE_DAYS = 1

# Open Notebook のエンドポイント
OPEN_NOTEBOOK_URL = "http://localhost:8502"

# ダウンロードした PDF の保存先
PDF_DIR = Path.home() / "open-notebook" / "arxiv_pdfs"

# 取得済み ID 記録ファイル（重複防止）
SEEN_IDS_FILE = Path.home() / "open-notebook" / ".seen_arxiv_ids.json"

# ─────────────────────────────────────────────────────────────────────────

# ログ設定
log_dir = Path.home() / "open-notebook"
log_dir.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(log_dir / "arxiv_fetcher.log", encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger(__name__)


def load_seen_ids() -> set:
    if SEEN_IDS_FILE.exists():
        with open(SEEN_IDS_FILE, encoding="utf-8") as f:
            return set(json.load(f))
    return set()


def save_seen_ids(ids: set):
    with open(SEEN_IDS_FILE, "w", encoding="utf-8") as f:
        json.dump(sorted(ids), f, indent=2, ensure_ascii=False)


def fetch_papers(query: str, max_results: int, since_days: int) -> list:
    """arXiv API から論文を取得する"""
    client = arxiv.Client(num_retries=3, delay_seconds=3)
    search = arxiv.Search(
        query=query,
        max_results=max_results,
        sort_by=arxiv.SortCriterion.SubmittedDate,
        sort_order=arxiv.SortOrder.Descending,
    )
    cutoff = datetime.now(timezone.utc) - timedelta(days=since_days)
    results = []
    try:
        for paper in client.results(search):
            if paper.published and paper.published < cutoff:
                break
            results.append(paper)
    except Exception as e:
        log.error(f"  arXiv API エラー: {e}")
    return results


def download_pdf(paper, dest_dir: Path) -> Path | None:
    """PDF をダウンロードして保存パスを返す"""
    dest_dir.mkdir(parents=True, exist_ok=True)
    arxiv_id = paper.entry_id.split("/")[-1]
    safe_id = arxiv_id.replace("/", "_")
    pdf_path = dest_dir / f"{safe_id}.pdf"

    if pdf_path.exists():
        log.info(f"  [CACHE] {pdf_path.name} は取得済みです。")
        return pdf_path
    try:
        paper.download_pdf(dirpath=str(dest_dir), filename=f"{safe_id}.pdf")
        log.info(f"  [DL]    {pdf_path.name}  ({pdf_path.stat().st_size // 1024} KB)")
        return pdf_path
    except Exception as e:
        log.error(f"  [ERR]   PDF ダウンロード失敗 ({arxiv_id}): {e}")
        return None


def register_to_open_notebook(paper, pdf_path: Path) -> bool:
    """
    Open Notebook REST API へ PDF を登録する。

    Open Notebook の Source API エンドポイントは将来変更される可能性があります。
    接続エラーの場合は PDF を手動でアップロードしてください。
    """
    # アップロード用エンドポイント（Open Notebook の実装に依存）
    url = f"{OPEN_NOTEBOOK_URL}/api/source"
    try:
        with open(pdf_path, "rb") as f:
            resp = requests.post(
                url,
                files={"file": (pdf_path.name, f, "application/pdf")},
                data={
                    "title":       paper.title,
                    "description": paper.summary[:500] if paper.summary else "",
                    "tags":        ",".join(paper.categories),
                    "arxiv_id":    paper.entry_id.split("/")[-1],
                    "authors":     ", ".join(str(a) for a in paper.authors[:5]),
                },
                timeout=60,
            )
        if resp.status_code in (200, 201):
            log.info(f"  [OK]    登録完了: {paper.title[:60]}")
            return True
        elif resp.status_code == 404:
            # API エンドポイントが存在しない場合は PDF ファイルだけ保存
            log.warning(
                f"  [SKIP]  Open Notebook API が応答しません (404)。"
                f"PDF は {pdf_path} に保存されています。手動でアップロードしてください。"
            )
            return True  # ID は記録してダウンロードを再度行わないようにする
        else:
            log.warning(f"  [WARN]  API ステータス {resp.status_code}: {resp.text[:200]}")
            return False

    except requests.exceptions.ConnectionError:
        log.error(
            "  [ERR]   Open Notebook に接続できません。\n"
            "          → Docker コンテナが起動しているか確認: docker compose up -d\n"
            f"         → PDF は {pdf_path} に保存しました。後で手動アップロードが可能です。"
        )
        return False  # 接続エラーの場合は再試行のため False
    except Exception as e:
        log.error(f"  [ERR]   登録失敗: {e}")
        return False


def write_summary_log(papers_meta: list, out_dir: Path):
    """
    取得した論文のメタ情報を Markdown でサマリーとして保存する。
    Open Notebook へのアップロードに失敗した場合も確認できます。
    """
    if not papers_meta:
        return
    today = datetime.now().strftime("%Y-%m-%d")
    md_path = out_dir / f"arxiv_summary_{today}.md"
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(f"# arXiv 取得サマリー {today}\n\n")
        for meta in papers_meta:
            f.write(f"## {meta['title']}\n\n")
            f.write(f"- **arXiv ID**: [{meta['arxiv_id']}](https://arxiv.org/abs/{meta['arxiv_id']})\n")
            f.write(f"- **著者**: {meta['authors']}\n")
            f.write(f"- **カテゴリ**: {meta['categories']}\n")
            f.write(f"- **公開日**: {meta['published']}\n")
            f.write(f"- **PDF**: {meta['pdf_path']}\n\n")
            f.write(f"> {meta['summary'][:300]}...\n\n")
            f.write("---\n\n")
    log.info(f"  [MD]    サマリーを保存しました: {md_path}")


def run(dry_run: bool = False):
    log.info("=" * 60)
    log.info(f"arXiv 取り込み開始: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log.info("=" * 60)

    seen_ids  = load_seen_ids()
    new_ids   = set()
    all_meta  = []
    total_new = 0

    for query, max_results, label in SEARCH_QUERIES:
        log.info(f"\n[{label}] クエリ: {query}")
        papers = fetch_papers(query, max_results, SINCE_DAYS)
        log.info(f"  → {len(papers)} 件取得")

        for paper in papers:
            arxiv_id = paper.entry_id.split("/")[-1]

            if arxiv_id in seen_ids:
                log.info(f"  [SKIP]  取得済み: {arxiv_id}")
                continue

            log.info(f"  [NEW]   {arxiv_id} | {paper.title[:55]}")
            total_new += 1

            meta = {
                "arxiv_id":   arxiv_id,
                "title":      paper.title,
                "authors":    ", ".join(str(a) for a in paper.authors[:5]),
                "categories": ", ".join(paper.categories),
                "published":  str(paper.published)[:10],
                "summary":    paper.summary or "",
                "pdf_path":   "",
            }

            if dry_run:
                log.info("  [DRY]   --dry-run: ダウンロード・登録をスキップ")
                all_meta.append(meta)
                new_ids.add(arxiv_id)
                continue

            pdf_path = download_pdf(paper, PDF_DIR)
            if pdf_path:
                meta["pdf_path"] = str(pdf_path)
                all_meta.append(meta)
                success = register_to_open_notebook(paper, pdf_path)
                if success:
                    new_ids.add(arxiv_id)
                # 失敗してもメタ情報は記録

    # サマリー Markdown を保存
    if all_meta:
        write_summary_log(all_meta, PDF_DIR.parent)

    seen_ids |= new_ids
    save_seen_ids(seen_ids)

    log.info(f"\n✓ 完了: {total_new} 件の新規論文を処理しました。")
    log.info(f"  PDFフォルダ: {PDF_DIR}")
    log.info("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description="arXiv → Open Notebook 自動取り込みスクリプト",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--schedule", action="store_true",
                        help="毎日 08:00 に定期実行")
    parser.add_argument("--dry-run",  action="store_true",
                        help="PDF を取得するが Open Notebook へは送信しない")
    parser.add_argument("--time",     default="08:00",
                        help="定期実行時刻 HH:MM (デフォルト: 08:00)")
    args = parser.parse_args()

    if args.schedule:
        log.info(f"スケジューラ起動。毎日 {args.time} に実行します。")
        schedule.every().day.at(args.time).do(run, dry_run=args.dry_run)
        run(dry_run=args.dry_run)           # 起動直後に 1 回実行
        while True:
            schedule.run_pending()
            time.sleep(30)
    else:
        run(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
