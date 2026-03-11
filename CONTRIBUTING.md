# Building Hook Extensions

This repo is the **hook extension layer** for ERC-8183. Hooks let you extend `AgenticCommerceHooked` with custom logic — bidding rules, escrow flows, compliance checks, and more — without modifying the core protocol.

## Writing a Hook

### 1. Inherit `BaseACPHook`

```solidity
contract YourHook is BaseACPHook {
    constructor(address acpContract_) BaseACPHook(acpContract_) {}

    // Override only the callbacks you need
}
```

Available callbacks (all no-ops by default):

| Callback | Triggered by |
|----------|-------------|
| `_preSetProvider` / `_postSetProvider` | `setProvider` |
| `_preSetBudget` / `_postSetBudget` | `setBudget` |
| `_preFund` / `_postFund` | `fund` |
| `_preSubmit` / `_postSubmit` | `submit` |
| `_preComplete` / `_postComplete` | `complete` |
| `_preReject` / `_postReject` | `reject` |

`claimRefund` is deliberately not hookable.

### 3. Pick a profile

| Profile | When to use |
|---------|-------------|
| **A — Simple Policy** | Validation and light policy only (bidding, RFQ, KYC, limits). No extra token custody. |
| **B — Advanced Escrow** | Hooks that custody tokens and orchestrate multi-phase flows. |
| **C — Experimental** | Anything that doesn't fit A or B cleanly. Label clearly as high-risk. |

See [`hook-profiles.md`](./hook-profiles.md) for full guidance on each profile.

### 4. Document your hook

Include a NatSpec header in your contract explaining:

- **USE CASE** — what problem it solves
- **FLOW** — step-by-step, noting which steps are hook callbacks
- **TRUST MODEL** — what guarantees the hook provides and to whom

See `BiddingHook.sol` or `FundTransferHook.sol` for examples.

## Submitting to this repo

If you'd like your hook included here:

1. Add it to `contracts/hooks/`.
2. Add a row to the Hook Examples table in [`README.md`](./README.md):

```markdown
| [YourHook.sol](./contracts/hooks/YourHook.sol) | A / B / C | One-line description. |
```

3. Open a pull request — one hook per PR, with a brief description of the use case and any trust assumptions.

## Code style

- Solidity `^0.8.20`.
- Follow the style of existing contracts (named errors, NatSpec, no magic numbers).
- Keep hooks focused — one responsibility per hook.
- Avoid unnecessary state; prefer `mapping(uint256 => ...)` keyed by `jobId`.
