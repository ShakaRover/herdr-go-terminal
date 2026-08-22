use std::process::Command;

fn main() {
    let out = Command::new("git")
        .args(["rev-parse", "--short=8", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty());
    if let Some(hash) = out {
        println!("cargo:rustc-env=HERDRGO_BRIDGE_GIT_HASH={hash}");
    }
    println!("cargo:rerun-if-changed=../.git/HEAD");
}
