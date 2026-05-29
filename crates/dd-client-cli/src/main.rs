use std::path::PathBuf;

use anyhow::anyhow;
use clap::{Args, Parser, Subcommand};
use dd_client_core::{
    close_session, connect, create_session, enrollment_url, exec, list_recipes, list_sessions,
    public_key_hex, replay_session, resize_session, session_id, ConnectionOptions,
    CreateSessionRequest, ExecRequest, IntelTrustAuthority, QuoteVerification,
};
use dd_client_session::ViewMode;

mod session_ui;

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
    Recipes(ConnectArgs),
    Sessions(ConnectArgs),
    Create(CreateArgs),
    Replay(SessionArgs),
    Resize(ResizeArgs),
    Close(SessionArgs),
    Attach(SessionArgs),
    Watch(SessionArgs),
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

#[derive(Args, Clone)]
struct ConnectArgs {
    #[arg(long)]
    url: String,
    #[arg(long)]
    key: PathBuf,
    #[arg(long)]
    insecure_skip_quote_verify: bool,
    #[arg(long, env = "DD_ITA_JWKS_URL", default_value = DEFAULT_ITA_JWKS_URL)]
    ita_jwks_url: String,
    #[arg(long, env = "DD_ITA_ISSUER", default_value = DEFAULT_ITA_ISSUER)]
    ita_issuer: String,
    /// Structured deriver: "floor" (any TUI) or "claude" (Claude Code stream-json).
    #[arg(long, default_value = "floor")]
    adapter: String,
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
            print_json(replay_session(&mut conn, &args.id).await?)?;
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
            let adapter = args.connect.adapter.clone();
            let conn = connect(&connection_options(args.connect)?).await?;
            session_ui::run(conn, &args.id, ViewMode::Watch, &adapter).await?;
        }
        Command::Watch(args) => {
            let adapter = args.connect.adapter.clone();
            let conn = connect(&connection_options(args.connect)?).await?;
            session_ui::run(conn, &args.id, ViewMode::Watch, &adapter).await?;
        }
        Command::Shell(args) => {
            let adapter = args.connect.adapter.clone();
            let mut conn = connect(&connection_options(args.connect.clone())?).await?;
            let session = create_session(&mut conn, &create_request(&args)).await?;
            let id = session_id(&session)?;
            session_ui::run(conn, &id, ViewMode::Watch, &adapter).await?;
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
