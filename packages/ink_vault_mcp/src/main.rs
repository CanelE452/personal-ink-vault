use ink_vault_mcp::{BridgeClient, InkVaultServer};
use rmcp::{ServiceExt, transport::stdio};
use std::path::PathBuf;

#[tokio::main]
async fn main() {
    if run().await.is_err() {
        eprintln!(
            "Personal Ink Vault MCP 연결을 시작하지 못했습니다. --bridge-file <앱 연결 파일> 또는 INK_VAULT_MCP_BRIDGE를 확인하세요."
        );
        std::process::exit(2);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    let path = match args.next() {
        Some(flag) if flag == "--bridge-file" => {
            let path = args.next().ok_or("Missing bridge file")?;
            if args.next().is_some() {
                return Err("Unexpected argument".into());
            }
            PathBuf::from(path)
        }
        Some(_) => return Err("Unsupported argument".into()),
        None => PathBuf::from(
            std::env::var_os("INK_VAULT_MCP_BRIDGE").ok_or("Missing bridge configuration")?,
        ),
    };
    let server = InkVaultServer::new(BridgeClient::from_file(path)?)
        .serve(stdio())
        .await?;
    server.waiting().await?;
    Ok(())
}
