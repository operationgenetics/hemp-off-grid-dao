# Hemp Off-Grid DAO

Arbitrum One (chainid 42161) native DAO. OBS vault, bonding-curve unlock,
expiring monthly LP governance, hard-coded off-grid hemp programme rules, and
milestone-gated fund release authorised by a Roomie humanoid robot's hybrid-PQC MCU.

**Canonical source: `src/HempOffGridDAO.sol`.** There is exactly one contract file;
the old divergent copy under `contracts/` has been removed (it is in git history).

---

## Deploy — scan a QR with MetaMask, sign once

```bash
npm run deploy         # node deploy.js  [optional path/to/Contract.sol]
```

That single command compiles the contract, serves a self-contained signing page from
your own machine, and prints a QR code. Scan it with MetaMask mobile (menu → scan) or
your phone camera; the page opens in MetaMask's in-app browser with the wallet already
connected. Press **Deploy**, sign, and the address is reported straight back to the
terminal and written into `deployment-config.json`.

Desktop MetaMask works too — open the `http://localhost:8788` URL it prints. Or skip
the server entirely and open `build/deploy.html` directly; the ABI and bytecode are
inlined at compile time so it runs off `file://`.

No API key, no WalletConnect project ID, no relay server, no `.env`, no constructor
arguments, no config file. Point MetaMask at your own Arbitrum node and the whole path
touches no third-party infrastructure.

### Lowest gas fee

The page shows a live cost estimate and a Refresh button. On Arbitrum the dominant
term is the cost of posting your transaction to Ethereum L1, which Arbitrum already
folds into `eth_estimateGas` — so the number moves with the **Ethereum base fee**, not
with anything in this repo. Refresh until it is cheap, then sign.

Compiler settings barely matter here, and this was measured rather than assumed:
across `optimizer_runs` of 1 / 50 / 200 / 1000 / 10000 the compressed initcode spans
7,046–7,094 bytes (<1%) and full-lifecycle runtime gas spans 4.367M–4.370M (<0.1%).
The repo ships the audit-standard `runs = 200`. Deploy timing is worth several-fold
more than any of it.

---

## Hard-coded on-chain values

| | |
|---|---|
| OBS token | `0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0` |
| DAI (Arbitrum One) | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` |
| Robot registry admin | `0xaF570ce3b32D765b1236635B0f541a7487A1fB8e` |
| Bonding-curve unlock | 5,000,000,000 DAI (latching) |
| LP issuance | 100 LP per member per calendar month, expiring at month end |
| Proposal cost | 50 LP · Vote weight 1 LP = 1 vote, consumed on use |
| MCU authorisation interval | 60 days per project, minimum 3 milestones |
| Allocation | 50% temple pool / 50% community pool, split at deposit |

---

## Lifecycle

1. **Deploy.** No arguments. The admin wallet is seeded as the founding member so
   governance is usable immediately.
2. **`setupRoomieRobotAndLock`** — callable straight away with placeholders, and
   re-callable every time hardware changes. Registers the MCU's classical signer
   address, its PQC **public key**, an optional PQC verifier, and the bonding-curve
   reserve address.
3. **Fund the vault.** `depositOBS` splits 50/50 into the temple and community pools.
   `syncDirectOBSDeposits` rescues OBS sent by plain transfer.
4. **Real robot arrives.** Call `setupRoomieRobotAndLock` again with the true key.
5. **`revokeAndFinalize`** — one way. Destroys the admin role permanently; from then
   on no address can change anything. Refused on a placeholder key (<1312 bytes) so a
   stub cannot be locked in by accident.
6. **Curve hits 5B DAI.** Anyone calls `latchBondingCurveUnlock`. The unlock latches
   so a later dip cannot re-lock projects already under way.
7. **Projects run.** Proposal → vote → `finalizeProposal` opens a milestone-gated
   project → one `authorizeMilestoneAndRelease` per 60 days until complete.

The DAO keeps admitting members, registering temples, passing proposals and paying
out projects **after** immutability, with no privileged role in existence. This is
covered end-to-end by `test_FullLifecycleFromDeployToCompletedProjectAfterImmutability`.

---

## Hybrid PQC — what is actually enforced

`authorizeMilestoneAndRelease` requires **both** halves of the MCU's hybrid signature
over a digest bound to this chain, this contract, this project, this milestone, this
amount, this beneficiary and a single-use nonce:

* **Classical half** — secp256k1, verified natively on-chain by `ecrecover` against
  the registered `robotSignerEOA`, with low-`s` malleability rejection. Fully enforced.
* **Post-quantum half** — if `pqcVerifier` is registered, the contract calls it and a
  rejection blocks the release. If not, the signature is **required to be present** and
  is anchored on-chain (hash in state and in the `MilestoneAuthorized` event) bound to
  the digest and to `pqcPublicKeyHash`, for verification by the robots and any auditor.

**There is no ML-DSA/Dilithium precompile on Arbitrum One**, and a full verifier does
not fit in EVM bytecode at practical gas. The verifier slot is the honest upgrade path:
register one before `revokeAndFinalize` and the PQC half becomes natively enforced too.

**No biometric data is stored on-chain.** The contract has no field capable of holding
a template, hash or derivative. Templates stay locked on the robot's MCU; only the
public key is published.

---

## Programme rules enforced by the EVM

Every funding proposal is rejected at `createProposal` unless it names a
`ProductCategory` and a `SiteType` from the on-chain enums and sets all three
covenants true — `naturalColorOnly`, `offGridPoweredOnly`, `humanSafetyCovenant`.

Products: socks · pants/joggers · shorts · long sleeve · short sleeve · tank top ·
men's underwear · women's underwear · toilet paper · wipes, plus the grow itself:
solar · battery storage · atmospheric water generation · processing/mill · distribution.

`TempleSupply` draws only from the temple pool and only to an address registered as a
501(c)(7) Hindu temple vertical grow. `CommunitySupply` draws only from the community
pool. Neither can touch the other's half.

---

## Anti-dump

A project pays in equal tranches, one per 60 days, each needing a fresh MCU
authorisation that simultaneously attests the previous milestone complete. A project
therefore cannot be drained faster than `milestoneCount × 60 days` — 180 days minimum.
A programme-wide circuit breaker additionally caps releases at 5% of total deposits per
rolling 60-day window (`GLOBAL_RELEASE_CAP_BPS`), and over-cap tranches are rejected at
proposal time so a release can never deadlock.

---

## Audit posture

* **Reproducible build.** `solc` via `compile.js` and `forge` produce byte-identical
  bytecode. Settings are pinned in one place and mirrored in both toolchains
  (`0.8.24`, optimizer on, `runs = 200`, viaIR, `evmVersion = paris`, no metadata hash).
* **Static analysis.** `npm run slither` — the `locked-ether` finding was real and is
  fixed (the contract now has no payable function whatsoever, so ETH cannot enter).
  The three remaining detectors are analysed false positives, documented inline at the
  code they point at: balance-delta accounting behind `nonReentrant` on a constant
  token address; deliberate exact-remainder arithmetic in the calendar routine; and
  strict equality on bounded counters rather than balances.
* **Invariants.** 6 properties held across 128,000 fuzzed calls: the accounting
  identity, vault solvency, the temple half never being raided by community spending,
  the temple side never exceeding 50%, never paying out more than was taken in, and
  immutability being one-way.
* **No privileged role survives.** After `revokeAndFinalize` there is no admin, no
  owner, no pause, no upgrade path and no proxy. The DAO keeps admitting members,
  registering temples and paying projects with nothing privileged in existence.
* **Signature hygiene.** EIP-191 digests bound to chainid, contract, project,
  milestone, amount, beneficiary and a single-use nonce; low-`s` malleability rejected;
  `ecrecover` failure returns `address(0)` and is compared against a signer that setup
  guarantees is non-zero.

## Tests

```bash
forge test        # 54 passing: 44 unit + fuzz, 6 invariants, 4 legacy
```

Covering: the OBS address, the admin wallet, exact calendar-month LP issuance and
expiry across leap years, 50-LP proposals, 1:1 vote consumption, quorum and majority,
covenant rejection, temple registration, the 50/50 split, direct-transfer recovery,
the latching 5B unlock, valid/forged/replayed/missing MCU signatures, the PQC verifier
being genuinely called, the 60-day cadence, exact full payout with no dust, ETH refusal,
immutability after revocation, and the complete real-world lifecycle.
