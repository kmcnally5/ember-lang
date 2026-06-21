// Ember Zed extension. A thin launcher, mirroring editors/vscode/extension.js: it tells Zed how to
// start `emberc --lsp` (the in-tree C language server) and nothing more. All the intelligence lives
// in the compiler; this wasm module only wires the process up. Syntax highlighting comes from the
// bundled tree-sitter-ember grammar + languages/ember/highlights.scm, not from here.

use zed_extension_api::{self as zed, Command, LanguageServerId, Result};

// Fallback when emberc is not found on the worktree PATH. `make install` deploys it to ~/.ember/bin,
// so resolve that against $HOME (portable — no hardcoded user path); if $HOME is unavailable, fall
// back to a bare "emberc" and rely on PATH. Put emberc on your PATH to override either.
fn default_emberc() -> String {
    match std::env::var("HOME") {
        Ok(home) => format!("{home}/.ember/bin/emberc"),
        Err(_) => "emberc".to_string(),
    }
}

struct EmberExtension;

impl zed::Extension for EmberExtension {
    fn new() -> Self {
        EmberExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<Command> {
        // Prefer an emberc on the worktree PATH; otherwise fall back to the install location.
        let command = worktree
            .which("emberc")
            .unwrap_or_else(default_emberc);
        Ok(Command {
            command,
            args: vec!["--lsp".to_string()],
            // No EMBER_STD: emberc resolves the stdlib relative to its own binary (<bin>/../std),
            // which covers both a `make install` (~/.ember/std) and a repo build (build/../std).
            env: vec![],
        })
    }
}

zed::register_extension!(EmberExtension);
