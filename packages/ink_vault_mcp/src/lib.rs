use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{net::IpAddr, path::PathBuf, sync::Arc, time::Duration};
mod server;
pub use server::InkVaultServer;

pub const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
pub const READ_OPERATIONS: &[&str] = &[
    "vault_status",
    "list_documents",
    "search_documents",
    "list_folders",
    "read_document",
    "read_daily_note",
    "list_page_discussions",
    "list_revisions",
    "read_revision",
    "compare_page_revision",
    "render_page",
    "read_page_media",
    "database_query",
    "database_task_links",
    "query_dataview",
];
pub const WRITE_OPERATIONS: &[&str] = &[
    "create_document",
    "ensure_daily_note",
    "update_document",
    "mutate_page_discussion",
    "document_action",
    "restore_page_revision",
    "office_edit",
    "office_asset",
    "database_action",
];

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeConfig {
    pub version: u32,
    pub instance_id: String,
    pub endpoint: String,
    pub token: String,
    pub write_enabled: bool,
}

#[derive(Clone)]
enum ConfigSource {
    Fixed(Arc<BridgeConfig>),
    File {
        path: PathBuf,
        instance_id: Arc<tokio::sync::Mutex<Option<String>>>,
    },
}
#[derive(Clone)]
pub struct BridgeClient {
    source: ConfigSource,
    http: reqwest::Client,
}
impl BridgeClient {
    pub fn new(config: BridgeConfig) -> Result<Self, BridgeError> {
        Self::with_timeout(config, Duration::from_secs(120))
    }
    pub fn with_timeout(config: BridgeConfig, timeout: Duration) -> Result<Self, BridgeError> {
        validate_config(&config)?;
        Ok(Self {
            source: ConfigSource::Fixed(Arc::new(config)),
            http: http_client(timeout)?,
        })
    }
    pub fn from_file(path: PathBuf) -> Result<Self, BridgeError> {
        Ok(Self {
            source: ConfigSource::File {
                path,
                instance_id: Arc::new(tokio::sync::Mutex::new(None)),
            },
            http: http_client(Duration::from_secs(120))?,
        })
    }
    async fn config(&self) -> Result<Arc<BridgeConfig>, BridgeError> {
        match &self.source {
            ConfigSource::Fixed(config) => Ok(config.clone()),
            ConfigSource::File { path, .. } => {
                let metadata = tokio::fs::metadata(path).await.map_err(|_| {
                    BridgeError::new(
                        "app_not_running",
                        "Personal Ink Vault를 실행하고 로컬 AI 연결을 켜 주세요.",
                    )
                })?;
                if !metadata.is_file() || metadata.len() > 64 * 1024 {
                    return Err(BridgeError::config());
                }
                let bytes = tokio::fs::read(path)
                    .await
                    .map_err(|_| BridgeError::config())?;
                if bytes.len() > 64 * 1024 {
                    return Err(BridgeError::config());
                }
                let config: BridgeConfig =
                    serde_json::from_slice(&bytes).map_err(|_| BridgeError::config())?;
                validate_config(&config)?;
                Ok(Arc::new(config))
            }
        }
    }
    pub async fn call(&self, operation: &str, arguments: Value) -> Result<Value, BridgeError> {
        let writes = WRITE_OPERATIONS.contains(&operation);
        if !writes && !READ_OPERATIONS.contains(&operation) {
            return Err(BridgeError::new(
                "unknown_operation",
                "지원하지 않는 문서 작업입니다.",
            ));
        }
        if !arguments.is_object() {
            return Err(BridgeError::new(
                "invalid_arguments",
                "작업 인자는 객체여야 합니다.",
            ));
        }
        let config = self.config().await?;
        if let ConfigSource::File { instance_id, .. } = &self.source {
            let mut pinned = instance_id.lock().await;
            if let Some(instance) = pinned.as_ref() {
                if instance != &config.instance_id {
                    return Err(BridgeError::new(
                        "bridge_instance_changed",
                        "앱 또는 저장소 연결이 변경되었습니다. 대상 저장소를 확인하고 MCP 클라이언트를 다시 시작해 주세요.",
                    ));
                }
            } else {
                // Pin before HTTP: a failed response may follow a committed write.
                *pinned = Some(config.instance_id.clone());
            }
        }
        if writes && !config.write_enabled {
            return Err(BridgeError::new(
                "read_only",
                "앱에서 문서 수정 허용을 켜 주세요.",
            ));
        }
        let mut endpoint = validate_config(&config)?;
        endpoint.set_path("/v1/call");
        let body = serde_json::to_vec(
            &serde_json::json!({"operation":operation,"arguments":arguments}),
        )
        .map_err(|_| BridgeError::new("invalid_arguments", "작업 인자를 읽을 수 없습니다."))?;
        if body.len() > 2 * 1024 * 1024 {
            return Err(BridgeError::new(
                "request_too_large",
                "한 번에 수정할 문서 내용이 너무 큽니다.",
            ));
        }
        let mut response = self
            .http
            .post(endpoint)
            .bearer_auth(&config.token)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await
            .map_err(http_error)?;
        if response.status().is_redirection() {
            return Err(BridgeError::new(
                "redirect_forbidden",
                "앱 연결의 주소 변경 응답은 허용하지 않습니다.",
            ));
        }
        if response
            .content_length()
            .is_some_and(|size| size > MAX_RESPONSE_BYTES as u64)
        {
            return Err(BridgeError::new(
                "response_too_large",
                "앱 응답이 한 번에 읽을 수 있는 크기를 넘었습니다.",
            ));
        }
        let status = response.status();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(http_error)? {
            if bytes.len() + chunk.len() > MAX_RESPONSE_BYTES {
                return Err(BridgeError::new(
                    "response_too_large",
                    "앱 응답이 한 번에 읽을 수 있는 크기를 넘었습니다.",
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        let response: Value = serde_json::from_slice(&bytes).map_err(|_| {
            BridgeError::new("invalid_bridge_response", "앱 응답을 읽지 못했습니다.")
        })?;
        if response["ok"] == false {
            let code = response["error"]["code"].as_str().unwrap_or("bridge_error");
            let message = response["error"]["message"]
                .as_str()
                .unwrap_or("앱에서 문서 작업을 완료하지 못했습니다.");
            return Err(BridgeError::new(
                code,
                &message.replace(&config.token, "[redacted]"),
            ));
        }
        if !status.is_success() || response["ok"] != true || response.get("result").is_none() {
            return Err(BridgeError::new(
                "invalid_bridge_response",
                "앱에서 정상적인 작업 결과를 받지 못했습니다.",
            ));
        }
        Ok(response["result"].clone())
    }
}

#[derive(Debug)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
}
impl BridgeError {
    pub fn new(code: &str, message: &str) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
    fn config() -> Self {
        Self::new(
            "invalid_bridge_config",
            "앱 연결 설정을 확인하지 못했습니다. 앱에서 로컬 AI 연결을 다시 켜 주세요.",
        )
    }
}
impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for BridgeError {}

fn validate_config(config: &BridgeConfig) -> Result<reqwest::Url, BridgeError> {
    let url = reqwest::Url::parse(&config.endpoint).map_err(|_| BridgeError::config())?;
    let host = url.host_str().unwrap_or("").trim_matches(['[', ']']);
    let loopback = host.parse::<IpAddr>().is_ok_and(|ip| ip.is_loopback());
    if config.version != 1
        || config.instance_id.is_empty()
        || config.instance_id.len() > 128
        || config.token.is_empty()
        || config.token.len() > 4096
        || reqwest::header::HeaderValue::from_str(&format!("Bearer {}", config.token)).is_err()
        || url.scheme() != "http"
        || !loopback
        || url.port().is_none_or(|port| port == 0)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err(BridgeError::config());
    }
    Ok(url)
}
fn http_client(timeout: Duration) -> Result<reqwest::Client, BridgeError> {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(timeout)
        .build()
        .map_err(|_| {
            BridgeError::new(
                "bridge_transport_unavailable",
                "앱 연결 도구를 준비하지 못했습니다.",
            )
        })
}
fn http_error(error: reqwest::Error) -> BridgeError {
    if error.is_timeout() {
        BridgeError::new(
            "bridge_timeout",
            "앱 응답 시간이 초과되었습니다. 작업 상태를 확인한 뒤 같은 요청 ID로 다시 시도하세요.",
        )
    } else {
        BridgeError::new(
            "app_not_running",
            "Personal Ink Vault 앱이 실행 중인지 로컬 AI 연결이 켜져 있는지 확인하세요.",
        )
    }
}
