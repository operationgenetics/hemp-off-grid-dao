#!/usr/bin/env node
/**
 * Automated deployer for the Hemp Off-Grid DAO.
 *
 *   node deploy.js [path/to/Contract.sol]
 *
 * Compiles the contract, serves a self-contained signing page from this machine,
 * and prints a QR code. Scan it with the MetaMask mobile app (Menu -> scan, or your
 * phone camera) and the deploy page opens inside MetaMask's browser with the wallet
 * already connected. Press Deploy and sign. The address is reported straight back
 * here and written into deployment-config.json.
 *
 * Nothing to configure. No API key, no WalletConnect project ID, no relay server,
 * no constructor arguments. The only inputs are the source path and your signature.
 */
const fs = require('fs');
const os = require('os');
const http = require('http');
const path = require('path');
const qrcode = require('qrcode-terminal');
const { execFileSync } = require('child_process');
const { compile, renderDeployPage } = require('./compile');

const SOURCE = process.argv[2] || null;
const PORT = Number(process.env.PORT) || 8788;

// WalletConnect needs a project id from cloud.reown.com. Without one the page still
// works over injected MetaMask; the WalletConnect button is simply disabled.
const WC_PROJECT_ID =
  process.env.WALLETCONNECT_PROJECT_ID ||
  (fs.existsSync('.walletconnect-project-id')
    ? fs.readFileSync('.walletconnect-project-id', 'utf8').trim()
    : '');

// Only used by WalletConnect sessions, which need an RPC of their own. Override with
// ARBITRUM_RPC to point at your own node and keep the whole path off-grid.
const ARB_RPC = process.env.ARBITRUM_RPC || 'https://arb1.arbitrum.io/rpc';

const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const yellow = (s) => `\x1b[33m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;

/** First non-internal IPv4 address, so a phone on the same network can reach us. */
function lanAddress() {
  for (const ifaces of Object.values(os.networkInterfaces())) {
    for (const i of ifaces || []) {
      if (i.family === 'IPv4' && !i.internal) return i.address;
    }
  }
  return null;
}

function main() {
  console.log(bold('\n  Hemp Off-Grid DAO — deployer\n'));

  let artifacts, artifact;
  try {
    process.stdout.write('  Compiling … ');
    artifacts = compile(SOURCE ? [SOURCE] : undefined);
    artifact = artifacts.HempOffGridDAO;
  } catch (e) {
    console.log(red('failed'));
    console.error('\n' + e.message);
    process.exit(1);
  }

  const bytes = (artifact.bytecode.length - 2) / 2;
  console.log(green('ok'));
  console.log(dim(`    ${artifact.contractName}  ${bytes.toLocaleString()} bytes initcode`));
  console.log(dim(`    ${artifact.compiler}, optimizer runs=${artifact.settings.runs}, viaIR`));
  console.log(dim(`    constructor arguments: ${artifact.abi.find((x) => x.type === 'constructor')?.inputs.length ?? 0}`));

  fs.mkdirSync('build', { recursive: true });
  for (const a of Object.values(artifacts)) {
    fs.writeFileSync(path.join('build', `${a.contractName}.json`), JSON.stringify(a, null, 2));
  }
  const page = renderDeployPage(artifacts)
    .replace('__WC_PROJECT_ID__', WC_PROJECT_ID)
    .replace('__ARB_RPC__', ARB_RPC);
  fs.writeFileSync(path.join('build', 'deploy.html'), page);

  const server = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/deployed') {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        try {
          const { address, txHash, deployer } = JSON.parse(body);
          console.log('\n' + green(bold('  Deployed.')));
          console.log(`    contract  ${bold(address)}`);
          console.log(`    tx        ${txHash}`);
          console.log(`    deployer  ${deployer}`);
          console.log(`    explorer  https://arbiscan.io/address/${address}`);

          const cfgPath = 'deployment-config.json';
          const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
          cfg.deployedAddress = address;
          cfg.deploymentTx = txHash;
          cfg.deployedAt = new Date().toISOString();
          fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + '\n');
          console.log(dim(`\n    recorded in ${cfgPath}`));

          console.log('\n  Next:');
          console.log('    1. ' + dim(`forge verify-contract ${address} ${SOURCE}:${artifact.contractName} --chain arbitrum`));
          console.log('    2. setupRoomieRobotAndLock — still open in the page, sign from 0xaF57…fB8e');
          console.log('    3. revokeAndFinalize — only once the real robot key is on-chain\n');
          console.log(dim('  Page still serving. Ctrl-C when finished.\n'));
        } catch (e) {
          console.error(red('  Could not record deployment: ' + e.message));
        }
        res.writeHead(204).end();
      });
      return;
    }

    // ExpandA(rho) for the verifier's one-time cache commitment. Computed here so the
    // browser never needs a PQC library; the CONTRACT re-derives and checks it anyway,
    // so a wrong answer from this endpoint cannot install a forged matrix.
    if (req.method === 'GET' && req.url.startsWith('/chunks')) {
      try {
        const pk = new URL(req.url, 'http://x').searchParams.get('pk');
        const hex = execFileSync('python3', ['tools/expand_a.py', pk], { encoding: 'utf8' }).trim();
        const raw = hex.replace(/^0x/, '');
        const chunks = [0, 1, 2].map((i) => '0x' + raw.slice(i * 20480, (i + 1) * 20480));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ chunks }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: String(e.message || e) }));
      }
    }

    // WalletConnect + QR bundle, served from this machine. Never a CDN.
    if (req.method === 'GET' && req.url === '/wc.js') {
      const f = path.join('build', 'wc.js');
      if (!fs.existsSync(f)) {
        res.writeHead(404).end('// bundle missing: npm run bundle');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8' });
      return res.end(fs.readFileSync(f));
    }

    if (req.method === 'GET' && (req.url === '/' || req.url.startsWith('/?'))) {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      return res.end(page);
    }

    res.writeHead(404).end('not found');
  });

  server.on('error', (e) => {
    console.error(red(`\n  Cannot listen on port ${PORT}: ${e.message}`));
    console.error(dim(`  Try: PORT=8899 node deploy.js\n`));
    process.exit(1);
  });

  server.listen(PORT, '0.0.0.0', () => {
    const lan = lanAddress();
    const url = lan ? `http://${lan}:${PORT}` : null;

    console.log('\n' + bold('  Open the deployer'));
    if (url) {
      console.log(dim('  This code is the page ADDRESS. Scanning it opens the deployer in'));
      console.log(dim("  MetaMask's in-app browser. Your phone must be on this network."));
      console.log(dim('  For a WalletConnect pairing code instead, open the page and press'));
      console.log(dim('  "Connect with WalletConnect" — that code is shown in the page.\n'));
      qrcode.generate(url, { small: true });
      console.log(`  ${bold(url)}`);
    } else {
      console.log(yellow('  No LAN address found — no QR to scan from another device.'));
    }
    console.log(`  ${bold(`http://localhost:${PORT}`)} ${dim('(desktop MetaMask on this machine)')}`);
    console.log(dim(`  build/deploy.html also works opened directly, with no server.\n`));

    console.log(bold('  Connecting MetaMask'));
    if (WC_PROJECT_ID) {
      console.log(dim('  WalletConnect is enabled. Open the page, press "Connect with'));
      console.log(dim('  WalletConnect", and scan the pairing code with the MetaMask app.'));
      console.log(dim('  Your phone stays inside MetaMask; it never opens a web page.\n'));
    } else {
      console.log(yellow('  WalletConnect is DISABLED: no project id.'));
      console.log(dim('  Get a free one at cloud.reown.com, then:'));
      console.log(dim('    WALLETCONNECT_PROJECT_ID=<id> node deploy.js'));
      console.log(dim('  Until then, use MetaMask in this browser at the localhost URL above.\n'));
    }

    console.log(bold('  Lowest gas fee'));
    console.log(dim('  Arbitrum folds the cost of posting your transaction to Ethereum L1'));
    console.log(dim('  into the gas estimate, and that L1 base fee is the dominant term — it'));
    console.log(dim('  swings several-fold through the day while everything on this side stays'));
    console.log(dim('  fixed. The page shows a live estimate; press Refresh until it is cheap,'));
    console.log(dim('  then sign. That timing saves far more than any compiler setting.\n'));

    console.log(dim('  Waiting for a deployment… Ctrl-C to stop.'));
  });
}

main();
