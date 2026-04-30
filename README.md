# smart-contract

> **⚠️ This repo is a placeholder. Active Solidity contracts live in [`wellex-io/core/contracts/`](https://github.com/wellex-io/core/tree/main/contracts).**

## Why this layout

Wellex's on-chain contracts (token, staking, rewards, referral payouts, vault) are tightly coupled to the Rust backend in [`wellex-io/core`](https://github.com/wellex-io/core) — the backend submits transactions through Privy and reads on-chain state. To keep deploy + integration changes atomic, the Foundry project lives next to the API code that drives it:

```
wellex-io/core/
├── contracts/
│   ├── foundry.toml
│   ├── remappings.txt
│   ├── src/        # Solidity sources
│   ├── test/       # Foundry tests
│   └── script/     # Deploy + admin scripts
├── crates/         # Rust workspace (mlm-api + infra + ...)
└── ...
```

When this repo's role becomes useful (e.g., an external audit firm needs an isolated submodule, or contracts decouple from the monolith), the contracts will be split out then. Until that point: contribute to `wellex-io/core/contracts/`.

## Where to look

| Concern | Path |
|---|---|
| Contract sources | [`wellex-io/core/contracts/src/`](https://github.com/wellex-io/core/tree/main/contracts/src) |
| Foundry tests | [`wellex-io/core/contracts/test/`](https://github.com/wellex-io/core/tree/main/contracts/test) |
| Deploy scripts | [`wellex-io/core/contracts/script/`](https://github.com/wellex-io/core/tree/main/contracts/script) |
| Live contract addresses (Polygon mainnet) | `WELLIX_*` env vars in `wellex-io/core/.env.example` |
| Architecture rationale | [`wellex-io/gateway/ARCHITECTURE.md`](https://github.com/wellex-io/gateway/blob/main/ARCHITECTURE.md) § 3 |

## When to revisit this repo

Open an issue here if any of the following becomes true:
- An external audit needs a contracts-only submodule.
- Contracts decouple from the Rust monolith (e.g., become reusable across multiple Wellex products).
- A separate engineering team is hired with permissions scoped to contracts only.
