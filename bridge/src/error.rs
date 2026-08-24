use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
    pub text_delivered: bool,
    pub extra: Option<serde_json::Map<String, serde_json::Value>>,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        ApiError {
            status,
            code,
            message: message.into(),
            text_delivered: false,
            extra: None,
        }
    }

    pub fn herdr(err: &crate::herdr::client::HerdrError) -> Self {
        if err.is_pane_not_found() {
            return ApiError::new(StatusCode::NOT_FOUND, "pane_not_found", err.to_string());
        }
        ApiError::new(StatusCode::BAD_GATEWAY, "herdr_error", err.to_string())
    }

    pub fn text_delivered() -> Self {
        ApiError {
            status: StatusCode::BAD_GATEWAY,
            code: "text_delivered",
            message: "typed into the pane but not submitted — check the pane before resending".into(),
            text_delivered: true,
            extra: None,
        }
    }

    pub fn with_extra(mut self, key: &str, value: serde_json::Value) -> Self {
        self.extra.get_or_insert_default().insert(key.to_string(), value);
        self
    }
}

pub fn security_headers() -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    h.insert("x-content-type-options", "nosniff".parse().unwrap());
    h.insert("referrer-policy", "no-referrer".parse().unwrap());
    h
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut body = serde_json::json!({"error": self.message, "code": self.code});
        if self.text_delivered { body["textDelivered"] = serde_json::json!(true); }
        if let Some(extra) = self.extra {
            for (key, value) in extra {
                body[&key] = value;
            }
        }
        let mut res = (self.status, axum::Json(body)).into_response();
        res.headers_mut().extend(security_headers());
        res
    }
}
