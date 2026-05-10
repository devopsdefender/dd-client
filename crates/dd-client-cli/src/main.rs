use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context};
use clap::{Args, Parser, Subcommand};
use dd_client_core::{
    attach_session, close_session, connect, create_session, enrollment_url, exec, list_recipes,
    list_sessions, public_key_hex, replay_session, resize_session, session_id, ConnectionOptions,
    CreateSessionRequest, ExecRequest, IntelTrustAuthority, QuoteVerification,
};

const DEFAULT_ITA_BASE_URL: &str = "https://api.trustauthority.intel.com";
const DEFAULT_ITA_JWKS_URL: &str = "https://portal.trustauthority.intel.com/certs";
const DEFAULT_ITA_ISSUER: &str = "https://portal.trustauthority.intel.com";

#[derive(Parser)]
#[command(name = "dd-client")]
#[command(about = "Native DevOps Defender client")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Keygen(KeygenArgs),
    Pubkey(KeyOnlyArgs),
    MobileLink(MobileLinkArgs),
    Recipes(ConnectArgs),
    Sessions(ConnectArgs),
    Create(CreateArgs),
    Replay(SessionArgs),
    Resize(ResizeArgs),
    Close(SessionArgs),
    Attach(SessionArgs),
    Shell(CreateArgs),
    Exec(ExecArgs),
}

#[derive(Args)]
struct KeyOnlyArgs {
    #[arg(long)]
    key: PathBuf,
}

#[derive(Args)]
struct KeygenArgs {
    #[arg(long)]
    key: PathBuf,
    #[arg(long)]
    cp_url: Option<String>,
    #[arg(long)]
    label: Option<String>,
}

#[derive(Args)]
struct MobileLinkArgs {
    #[arg(long)]
    url: String,
    #[arg(long)]
    id: String,
    #[arg(long)]
    key: Option<PathBuf>,
    #[arg(long)]
    include_key: bool,
}

#[derive(Args, Clone)]
struct ConnectArgs {
    #[arg(long)]
    url: String,
    #[arg(long)]
    key: PathBuf,
    #[arg(long)]
    insecure_skip_quote_verify: bool,
    #[arg(long, env = "DD_ITA_API_KEY")]
    ita_api_key: Option<String>,
    #[arg(long, env = "DD_ITA_BASE_URL", default_value = DEFAULT_ITA_BASE_URL)]
    ita_base_url: String,
    #[arg(long, env = "DD_ITA_JWKS_URL", default_value = DEFAULT_ITA_JWKS_URL)]
    ita_jwks_url: String,
    #[arg(long, env = "DD_ITA_ISSUER", default_value = DEFAULT_ITA_ISSUER)]
    ita_issuer: String,
}

#[derive(Args)]
struct CreateArgs {
    #[command(flatten)]
    connect: ConnectArgs,
    #[arg(long)]
    recipe: Option<String>,
    #[arg(long)]
    name: Option<String>,
    #[arg(long)]
    command: Option<String>,
}

#[derive(Args)]
struct SessionArgs {
    #[command(flatten)]
    connect: ConnectArgs,
    #[arg(long)]
    id: String,
    #[arg(long)]
    max_bytes: Option<usize>,
}

#[derive(Args)]
struct ResizeArgs {
    #[command(flatten)]
    connect: ConnectArgs,
    #[arg(long)]
    id: String,
    #[arg(long)]
    cols: u64,
    #[arg(long)]
    rows: u64,
}

#[derive(Args)]
struct ExecArgs {
    #[command(flatten)]
    connect: ConnectArgs,
    #[arg(long, default_value_t = 60)]
    timeout: u64,
    #[arg(last = true, required = true)]
    cmd: Vec<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Keygen(args) => {
            let pubkey = public_key_hex(&args.key).await?;
            println!("{pubkey}");
            if let Some(cp_url) = args.cp_url.as_deref() {
                let label = args
                    .label
                    .as_deref()
                    .ok_or_else(|| anyhow!("--label is required with --cp-url"))?;
                println!("{}", enrollment_url(cp_url, &pubkey, label));
            }
        }
        Command::Pubkey(args) => {
            println!("{}", public_key_hex(&args.key).await?);
        }
        Command::MobileLink(args) => {
            print_mobile_link(args).await?;
        }
        Command::Recipes(args) => {
            let mut conn = connect(&connection_options(args)?).await?;
            print_json(list_recipes(&mut conn).await?)?;
        }
        Command::Sessions(args) => {
            let mut conn = connect(&connection_options(args)?).await?;
            print_json(list_sessions(&mut conn).await?)?;
        }
        Command::Create(args) => {
            let mut conn = connect(&connection_options(args.connect.clone())?).await?;
            print_json(create_session(&mut conn, &create_request(&args)).await?)?;
        }
        Command::Replay(args) => {
            let mut conn = connect(&connection_options(args.connect)?).await?;
            print_json(replay_session(&mut conn, &args.id, args.max_bytes).await?)?;
        }
        Command::Resize(args) => {
            let mut conn = connect(&connection_options(args.connect)?).await?;
            print_json(resize_session(&mut conn, &args.id, args.cols, args.rows).await?)?;
        }
        Command::Close(args) => {
            let mut conn = connect(&connection_options(args.connect)?).await?;
            print_json(close_session(&mut conn, &args.id).await?)?;
        }
        Command::Attach(args) => {
            let opts = connection_options(args.connect)?;
            let conn = connect(&opts).await?;
            attach_session(conn, &args.id, Some(opts)).await?;
        }
        Command::Shell(args) => {
            let opts = connection_options(args.connect.clone())?;
            let mut conn = connect(&opts).await?;
            let session = create_session(&mut conn, &create_request(&args)).await?;
            let id = session_id(&session)?;
            attach_session(conn, &id, Some(opts)).await?;
        }
        Command::Exec(args) => {
            let mut conn = connect(&connection_options(args.connect)?).await?;
            print_json(
                exec(
                    &mut conn,
                    &ExecRequest {
                        cmd: args.cmd,
                        timeout_secs: args.timeout,
                    },
                )
                .await?,
            )?;
        }
    }
    Ok(())
}

async fn print_mobile_link(args: MobileLinkArgs) -> anyhow::Result<()> {
    let key_hex = if args.include_key {
        let key = args
            .key
            .as_deref()
            .ok_or_else(|| anyhow!("--key is required with --include-key"))?;
        Some(load_key_hex(key).await?)
    } else {
        None
    };
    let link = mobile_session_url(&args.url, &args.id, key_hex.as_deref());
    println!("{link}");

    if let Some(key) = args.key {
        println!();
        println!("pubkey: {}", public_key_hex(&key).await?);
        println!(
            "key import: xxd -p -c 256 {} | pbcopy",
            shell_quote_path(&key)
        );
    }

    println!();
    if args.include_key {
        println!();
        println!("warning: this link contains the Noise private key; treat the QR as secret");
    }

    println!();
    println!("Open this link on iPhone, or make a QR with:");
    println!("qrencode -t ansiutf8 '{}'", shell_escape_single(&link));
    Ok(())
}

fn mobile_session_url(agent_url: &str, session_id: &str, key_hex: Option<&str>) -> String {
    let mut url = format!(
        "devopsdefender://session?agent={}&id={}&skip_quote_verify=1",
        percent_encode(agent_url),
        percent_encode(session_id)
    );
    if let Some(key_hex) = key_hex {
        url.push_str("&key=");
        url.push_str(&percent_encode(key_hex));
    }
    url
}

async fn load_key_hex(path: &Path) -> anyhow::Result<String> {
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("read {}", path.display()))?;
    if bytes.len() != 32 {
        anyhow::bail!("{} is {} bytes, expected 32", path.display(), bytes.len());
    }
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn percent_encode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn shell_quote_path(path: &std::path::Path) -> String {
    shell_quote(&path.to_string_lossy())
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", shell_escape_single(value))
}

fn shell_escape_single(value: &str) -> String {
    value.replace('\'', "'\\''")
}

fn create_request(args: &CreateArgs) -> CreateSessionRequest {
    CreateSessionRequest {
        recipe: args.recipe.clone(),
        name: args.name.clone(),
        command: args.command.clone(),
    }
}

fn connection_options(args: ConnectArgs) -> anyhow::Result<ConnectionOptions> {
    let quote_verification = if args.insecure_skip_quote_verify {
        QuoteVerification::InsecureSkip
    } else {
        QuoteVerification::IntelTrustAuthority(IntelTrustAuthority {
            api_key: args
                .ita_api_key
                .context("DD_ITA_API_KEY or --ita-api-key is required")?,
            base_url: args.ita_base_url,
            jwks_url: args.ita_jwks_url,
            issuer: args.ita_issuer,
        })
    };
    Ok(ConnectionOptions {
        agent_url: args.url,
        key_path: args.key,
        quote_verification,
    })
}

fn print_json(value: serde_json::Value) -> anyhow::Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}
