# Wikipedia RecentChange Stream on GCP

Wikimedia EventStreams（SSE）を購読し、Cloud Run 上のサービスが編集イベントを JSON でログ出力し、それをログシンク経由で Pub/Sub と BigQuery に流す小さなパイプラインです。

## これは何をする？

- Cloud Run 上で Flask アプリが Wikimedia の `recentchange` ストリームに接続します。
- 各イベントを `{ kind, dt, id, raw_json }` に包んで stdout に出力します。
- Logging のシンクがそのログをフィルタして Pub/Sub に送ります。
- Pub/Sub のサブスクリプションが BigQuery テーブルに書き込みます（`publish_time` で日次パーティション）。

## 構成

- `wikistream/main.py`: SSE コンシューマ + Flask ヘルスエンドポイント。
- `wikistream/Dockerfile`: Cloud Run 用コンテナイメージ。
- `wikistream/requirements.txt`: Python 依存。
- `main.tf`, `variables.tf`, `versions.tf`: API 有効化、Cloud Run、Pub/Sub、Logging シンク、BigQuery の Terraform。

## 必要なもの

- Terraform >= 1.6
- 請求が有効な Google Cloud プロジェクト
- Docker（コンテナビルド用）
- gcloud CLI（認証 + Artifact Registry 用）

## 設定

アプリが使う環境変数:

- `STREAM_URL`（既定: `https://stream.wikimedia.org/v2/stream/recentchange`）
- `USER_AGENT`（連絡先入りの適切な UA を設定推奨）

Terraform 変数（`variables.tf` を参照）:

- `project_id`
- `region`
- `service_name`

## デプロイ（Terraform + Cloud Run）

1) 認証とプロジェクト設定:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

2) Artifact Registry を作成（または既存を使用）してイメージをビルド/プッシュ。ここでは `apps` を使います:

```bash
REGION=asia-northeast1
PROJECT_ID=YOUR_PROJECT_ID
REPO=apps
IMAGE=wikistream:0.1.6

gcloud artifacts repositories create "$REPO" --location "$REGION" --repository-format docker

docker build -t "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/$IMAGE" ./wikistream

docker push "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/$IMAGE"
```

3) 必要なら `main.tf` のイメージタグを更新:

- `google_cloud_run_v2_service.hello.template.containers.image`

4) Terraform を適用:

```bash
terraform init
terraform apply
```

## ローカル実行（任意）

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r wikistream/requirements.txt
python wikistream/main.py
```

ヘルスチェック:

```bash
curl http://localhost:8080/
```

## 補足

- ログシンクのフィルタは `jsonPayload.kind="wiki_edit"` を前提にしています。
- Cloud Run は `min_instance_count = 1`、`max_instance_count = 1` に設定されています。
- BigQuery テーブルは `publish_time` でパーティションされます。
