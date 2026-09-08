#!/usr/bin/env node
/**
 * Local Solidity compiler. No network, no API key, no config.
 * Settings mirror foundry.toml exactly, so the deployed bytecode is byte-identical
 * to what the test suite and any auditor compiled.
 *
 *   node compile.js                       # builds every contract below
 *   node compile.js src/Foo.sol           # builds one
 */
const fs = require('fs');
const path = require('path');
const solc = require('solc');

const TARGETS = ['src/HempOffGridDAO.sol', 'src/crypto/MLDSA65Verifier.sol'];

// Must stay in lockstep with foundry.toml.
const SETTINGS = {
  optimizer: { enabled: true, runs: 200 },
  viaIR: true,
  evmVersion: 'paris',
  metadata: { bytecodeHash: 'none' },
  outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.methodIdentifiers'] } },
};

/** Collect a source and everything it imports, keyed by repo-relative path so that
 *  solc resolves relative imports the same way the file system does. */
function gather(entry, sources = {}) {
  const key = path.normalize(entry);
  if (sources[key]) return sources;
  const content = fs.readFileSync(key, 'utf8');
  sources[key] = { content };
  for (const m of content.matchAll(/^\s*import\s+"([^"]+)"/gm)) {
    if (m[1].startsWith('.')) gather(path.join(path.dirname(key), m[1]), sources);
  }
  return sources;
}

function compile(files = TARGETS) {
  const sources = {};
  for (const f of files) gather(f, sources);

  const out = JSON.parse(
    solc.compile(JSON.stringify({ language: 'Solidity', sources, settings: SETTINGS }))
  );
  const errors = (out.errors || []).filter((e) => e.severity === 'error');
  if (errors.length) throw new Error(errors.map((e) => e.formattedMessage).join('\n'));

  const artifacts = {};
  for (const f of files) {
    const key = path.normalize(f);
    const name = path.basename(f, '.sol');
    const c = out.contracts[key] && out.contracts[key][name];
    if (!c) throw new Error(`No contract ${name} in ${f}`);
    artifacts[name] = {
      contractName: name,
      sourceFile: key,
      abi: c.abi,
      bytecode: '0x' + c.evm.bytecode.object,
      methodIdentifiers: c.evm.methodIdentifiers,
      compiler: solc.version(),
      settings: { optimizer: true, runs: SETTINGS.optimizer.runs, viaIR: true, evmVersion: 'paris' },
    };
  }
  return artifacts;
}

/** Inline both artifacts so the page runs from file:// with no fetch and no CORS. */
function renderDeployPage(artifacts, template = 'deploy.template.html') {
  return fs.readFileSync(template, 'utf8').replace('/*__ARTIFACTS__*/', JSON.stringify(artifacts));
}

function writeBuild(files = TARGETS) {
  const artifacts = compile(files);
  fs.mkdirSync('build', { recursive: true });
  for (const a of Object.values(artifacts)) {
    fs.writeFileSync(path.join('build', `${a.contractName}.json`), JSON.stringify(a, null, 2));
  }
  fs.writeFileSync(path.join('build', 'deploy.html'), renderDeployPage(artifacts));
  return artifacts;
}

module.exports = { compile, renderDeployPage, writeBuild, TARGETS };

if (require.main === module) {
  const files = process.argv.length > 2 ? process.argv.slice(2) : TARGETS;
  try {
    const artifacts = writeBuild(files);
    for (const a of Object.values(artifacts)) {
      console.log(`${a.contractName}: ${(a.bytecode.length - 2) / 2} bytes initcode -> build/${a.contractName}.json`);
    }
    console.log('build/deploy.html  (self-contained)');
    console.log('\nRun `node deploy.js` to deploy by scanning a QR code with MetaMask.');
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
