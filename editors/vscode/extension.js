// Ember VS Code client. A thin launcher: it starts `emberc --lsp` (the in-tree C language server)
// over stdio and lets vscode-languageclient broker the JSON-RPC. All the intelligence lives in the
// compiler — this file only wires the process up and tells VS Code that `.em` files are `ember`.

const { workspace } = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const cfg = workspace.getConfiguration("emberLsp");
  const command = cfg.get("serverPath") || "/Users/karlmcnally/.ember/bin/emberc";
  const stdPath = cfg.get("stdPath") || "/Users/karlmcnally/.ember/std";

  const serverOptions = {
    command,
    args: ["--lsp"],
    // Pass EMBER_STD explicitly (belt-and-suspenders; the binary also finds std relative to itself).
    options: { env: Object.assign({}, process.env, { EMBER_STD: stdPath }) }
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "ember" }],
    synchronize: { fileEvents: workspace.createFileSystemWatcher("**/*.em") }
  };

  client = new LanguageClient("emberLsp", "Ember Language Server", serverOptions, clientOptions);
  client.start();
  context.subscriptions.push(client);
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
