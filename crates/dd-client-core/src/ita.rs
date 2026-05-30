use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, Context};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

const ALLOWED_ALGS: &[Algorithm] = &[
    Algorithm::RS256,
    Algorithm::RS384,
    Algorithm::RS512,
    Algorithm::ES256,
    Algorithm::ES384,
    Algorithm::PS256,
    Algorithm::PS384,
    Algorithm::PS512,
    Algorithm::EdDSA,
];

const LEEWAY_SECS: u64 = 120;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Claims {
    pub exp: i64,
    pub iat: i64,
    #[serde(default)]
    pub tcb_status: Option<String>,
    #[serde(default)]
    pub attester_type: Option<String>,
    #[serde(default)]
    pub mrtd: Option<String>,
    #[serde(default)]
    pub mrsigner: Option<String>,
    #[serde(default)]
    pub report_data: Option<String>,
    #[serde(default)]
    pub extra: serde_json::Value,
}

impl Claims {
    fn from_value(v: serde_json::Value) -> Self {
        let get = |k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
        Self {
            exp: v.get("exp").and_then(|x| x.as_i64()).unwrap_or(0),
            iat: v.get("iat").and_then(|x| x.as_i64()).unwrap_or(0),
            tcb_status: get("attester_tcb_status"),
            attester_type: get("attester_type"),
            mrtd: get("tdx_mrtd"),
            mrsigner: get("tdx_mrsigner"),
            // Intel TDX tokens carry the quote's report_data as `tdx_report_data`.
            report_data: get("tdx_report_data"),
            extra: v,
        }
    }
}

pub struct Verifier {
    jwks_url: String,
    issuer: String,
    http: Client,
    keys: RwLock<HashMap<String, DecodingKey>>,
}

impl Verifier {
    pub fn new(http: Client, jwks_url: String, issuer: String) -> Arc<Self> {
        Arc::new(Self {
            jwks_url,
            issuer,
            http,
            keys: RwLock::new(HashMap::new()),
        })
    }

    pub async fn verify(&self, token: &str) -> anyhow::Result<Claims> {
        let header = jsonwebtoken::decode_header(token).context("ita header")?;
        if !ALLOWED_ALGS.contains(&header.alg) {
            anyhow::bail!("ita alg {:?} not allowed", header.alg);
        }
        let kid = header.kid.ok_or_else(|| anyhow!("ita token missing kid"))?;

        let key = match self.lookup(&kid).await {
            Some(k) => k,
            None => {
                self.refresh().await?;
                self.lookup(&kid)
                    .await
                    .ok_or_else(|| anyhow!("ita kid {kid} not in JWKS"))?
            }
        };

        let mut validation = Validation::new(header.alg);
        validation.set_issuer(&[&self.issuer]);
        validation.leeway = LEEWAY_SECS;
        validation.set_required_spec_claims(&["exp", "iat", "iss"]);

        let data = jsonwebtoken::decode::<serde_json::Value>(token, &key, &validation)
            .context("ita verify")?;
        Ok(Claims::from_value(data.claims))
    }

    async fn lookup(&self, kid: &str) -> Option<DecodingKey> {
        self.keys.read().await.get(kid).cloned()
    }

    async fn refresh(&self) -> anyhow::Result<()> {
        let resp = self
            .http
            .get(&self.jwks_url)
            .send()
            .await
            .with_context(|| format!("JWKS fetch {}", self.jwks_url))?;
        if !resp.status().is_success() {
            anyhow::bail!("JWKS {}: HTTP {}", self.jwks_url, resp.status());
        }
        let jwks: jsonwebtoken::jwk::JwkSet = resp.json().await.context("JWKS parse")?;

        let mut map = HashMap::new();
        for jwk in &jwks.keys {
            let Some(kid) = &jwk.common.key_id else {
                continue;
            };
            if let Ok(key) = DecodingKey::from_jwk(jwk) {
                map.insert(kid.clone(), key);
            }
        }
        *self.keys.write().await = map;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn reject_algorithm_none() {
        let token = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.e30.";
        let verifier = Verifier::new(Client::new(), "http://127.0.0.1:1/".into(), "x".into());
        assert!(verifier.verify(token).await.is_err());
    }

    #[test]
    fn claims_map_intel_wire_names() {
        let v = serde_json::json!({
            "exp": 123,
            "iat": 1,
            "attester_tcb_status": "UpToDate",
            "attester_type": "TDX",
            "tdx_mrtd": "aa",
            "tdx_mrsigner": "bb",
            "tdx_report_data": "cc",
        });
        let claims = Claims::from_value(v.clone());
        assert_eq!(claims.exp, 123);
        assert_eq!(claims.tcb_status.as_deref(), Some("UpToDate"));
        assert_eq!(claims.mrtd.as_deref(), Some("aa"));
        assert_eq!(claims.mrsigner.as_deref(), Some("bb"));
        assert_eq!(claims.report_data.as_deref(), Some("cc"));
        assert_eq!(claims.extra, v);
    }
}
