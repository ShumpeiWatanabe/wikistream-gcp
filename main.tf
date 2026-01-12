provider "google" {
  project = var.project_id
  region  = var.region
}

# --- APIs (初回は serviceusage が未有効だとここで詰まることがあります) ---
resource "google_project_service" "serviceusage" {
  service            = "serviceusage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.serviceusage]
}

resource "google_project_service" "iam" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.serviceusage]
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.serviceusage]
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.serviceusage]
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.serviceusage]
}

resource "google_project_service" "bigquery" {
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudscheduler" {
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "pubsub" {
  service            = "pubsub.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.serviceusage]
}


# --- runtime service account ---
resource "google_service_account" "run_runtime" {
  account_id   = "${var.service_name}-sa"
  display_name = "Cloud Run runtime SA for ${var.service_name}"
  depends_on   = [google_project_service.iam]
}

# --- Cloud Run (v2) Service ---
resource "google_cloud_run_v2_service" "hello" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.run_runtime.email

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}/wikistream:0.1.6"

      env {
        name  = "STREAM_URL"
        value = "https://stream.wikimedia.org/v2/stream/recentchange"
      }
      # User-Agent はちゃんとした文字列に変えるの推奨
      env {
        name  = "USER_AGENT"
        value = "shumpei-wikistream/0.1 (contact:you@example.com)"
      }

      ports { container_port = 8080 }
    }

    scaling {
      min_instance_count = 1 # 一時的に止めたいので0にする。起動しっぱなしにするには1
      max_instance_count = 1
    }
  }

  deletion_protection = false

  depends_on = [
    google_project_service.run,
    google_project_service.iam,
    google_project_service.storage,
    google_project_service.artifactregistry
  ]
}


# --- Public access: allUsers に roles/run.invoker ---
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.hello.name

  role   = "roles/run.invoker"
  member = "allUsers" # 公開（未認証呼び出し許可） :contentReference[oaicite:5]{index=5}
}

resource "google_artifact_registry_repository" "apps" {
  location      = var.region
  repository_id = "apps"
  format        = "DOCKER"

  depends_on = [google_project_service.artifactregistry]
}

# pubsub topic 
resource "google_pubsub_topic" "wiki_edits" {
  name       = "wiki-edits"
  depends_on = [google_project_service.pubsub]
}

# logging sink to pubsub
resource "google_logging_project_sink" "wiki_edits_to_pubsub" {
  name        = "wiki-edits-to-pubsub"
  destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${google_pubsub_topic.wiki_edits.name}"

  # 編集イベントだけ（あなたのJSONに kind を入れてる前提）
  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.service_name}"
    jsonPayload.kind="wiki_edit"
  EOT

  unique_writer_identity = true
}

# sink の writer identity に publish 権限を付与
resource "google_pubsub_topic_iam_member" "sink_can_publish" {
  topic  = google_pubsub_topic.wiki_edits.name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.wiki_edits_to_pubsub.writer_identity
}


resource "google_bigquery_dataset" "wiki" {
  dataset_id                  = "wiki_edits_dataset"
  location                    = var.region
}

resource "google_bigquery_dataset_iam_member" "pubsub_bq_writer" {
  dataset_id = google_bigquery_dataset.wiki.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

data "google_project" "this" {
  project_id = var.project_id
}


resource "google_bigquery_table" "wiki_edit_logentry_p" {
  dataset_id = google_bigquery_dataset.wiki.dataset_id
  table_id   = "wiki_edit_logentry_p"

  schema = jsonencode([
    { name = "data", type = "JSON", mode = "NULLABLE" },
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id",        type = "STRING", mode = "NULLABLE" },
    { name = "publish_time",      type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "attributes",        type = "JSON", mode = "NULLABLE" },
    { name = "ordering_key",      type = "STRING", mode = "NULLABLE" }
  ])

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }
}

resource "google_pubsub_subscription" "wiki_edits_to_bq_p" {
  name  = "wiki-edits-to-bq-p"
  topic = google_pubsub_topic.wiki_edits.id

  bigquery_config {
    table          = "${var.project_id}:${google_bigquery_dataset.wiki.dataset_id}.${google_bigquery_table.wiki_edit_logentry_p.table_id}"
    write_metadata = true
  }

  depends_on = [google_bigquery_table.wiki_edit_logentry_p]
}