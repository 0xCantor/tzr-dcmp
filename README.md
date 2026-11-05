# Tessera propAMM (Base) reconstruction

## Architecture

```
trader ─► TesseraSwap (router) ─► TesseraEngine ─► book proxy ─► TesseraBook (logic)
              │                    (manager + factory)    │
              └─ moves tokens ◄── treasury (inventory)    └─ prices only, never moves tokens
```

- **Router (`TesseraSwap`)**: pays output from the treasury and pulls input from the caller. Forwards its `msg.sender` as `sender`.
- **Engine**: book manager, book factory and proxy admin of every book. Maps a pair to a book (direct, else via `hub`). Calls `sell` (exact in) or `buy` (exact out). Holds the kill switch, address labels, level-exclusion deadline and priority-fee reference. Roles: multisig (hardcoded), `owner` (router), `killer`, `exclusionSetter`.
- **Book proxy (`TesseraBookProxy`)**: one per pair, created by `createBook`. Holds the quote update path. An allowed updater (one of 10 immutables) sends a raw 32-byte word that is stored in slot 0 if the tag advanced by 1 to 15 (~27k gas). Any other call is delegated to the implementation.
- **Book (`TesseraBook`)**: shared implementation. State:
  - `Quote`: tag, refBlock, priceAnchor, spreadPpm.
  - Two sides of the clob (bids, asks), ≤19 levels + terminator. Level price = top-of-book price * multiplier. Replaced wholesale by `updateBook`.
  - Two flow accumulators. They reset on each book update and opposite flow nets against own flow at the anchor.
- **Swap**: walk the side (skip excluded levels and depth already consumed by net flow) -> gross output -> `out = gross × (1 − fee)`. Previews carry no mode fee.
- **Fee (ppm, capped at 1e6)**: mode + age + base + default + priority + address. Age = grace, then quadratic, then no fill at expiry. Address = blacklist, penalized or fingerprint helper. Default fee is flipped within blocks by the operator.

## Why price updates are cheap

- The updater call reaches the proxy fallback, which writes the calldata word straight to slot 0. There is no `delegatecall` to the implementation, no selector dispatch and no ABI decoding.
- The only checks are `msg.sender` against 10 immutables (no storage read) and the tag step. The cost is one `SLOAD` and one `SSTORE`, median 26.7k gas (from the paper), of which 21k is the transaction floor.
- Level prices are derived from the quote, so one write reprices every level:

$$p_{ask}=\left\lceil p\,\frac{10^6+s}{10^6}\right\rceil,\quad p_{bid}=\left\lfloor p\,\frac{10^6-s}{10^6}\right\rfloor,\quad p_k=p_{best}\,\frac{m_k}{10^6}$$

  with anchor $p$, spread $s$ (ppm) and level multiplier $m_k$. Rewriting the ladders (`updateBook`) costs 152k gas median and is needed about once per 4.31 blocks, against once per 0.563 blocks for the quote.
- There is one liquidity provider (from the paper), so there is no per-LP or per-order state to validate on update.
- `delegatecall` avoidance and the single-slot layout come from the bytecode. The paper does not discuss them.

## Source-dependent fees

The output of a swap is reduced by the sum of six components, capped at 100%:

$$\phi=\min\left(10^6,\ \phi_{mode}+\phi_{age}+\phi_{base}+\phi_{default}+\phi_{prio}+\phi_{addr}\right),\quad Y_{exec}=Y_{book}\left(1-\frac{\phi}{10^6}\right)$$

Exact-out grosses up the requested output first: $Y_{book}=\lceil Y_{exec}\,10^6/(10^6-\phi)\rceil$.

- **Priority.** With $t=\max(0,\ \text{gasprice}-\text{basefee})$ and $T=R\,\mu/10^6$ ($R$ is `priorityFeeReference` in the engine, $\mu$ is `priorityMultiplierPpm` in the book):

$$\phi_{prio}=\begin{cases}\text{priorityFee} & t>T\\ 0 & \text{otherwise}\end{cases}$$

  It targets trades that bid for a block position ahead of the operator's quote update.
- **Age.** With $a=\text{block.number}-\text{refBlock}$, grace $g$, expiry $E$, coefficient $c$ and cap $C$:

$$\phi_{age}=\begin{cases}0 & a<g\\ \min\left(C,\ c\,(a-g+1)^2\right) & g\le a<E\\ \text{no fill} & a\ge E\ \text{or}\ \text{refBlock}>\text{block.number}\end{cases}$$

- **Default.** `defaultFee`, set by the operator and bound to a block number so it can change within a block. It is $0$ if `sender` or `tx.origin` is default-exempt.
- **Address.** Labels come from the engine and apply to both `sender` and `tx.origin`. In whitelist-only mode only default-exempt senders trade and no address fee is charged. Otherwise a blacklisted address reverts, a penalized address pays `addressFee` and any other address pays `addressFee` only if the fingerprint helper matches.
- **Mode.** An external helper maps the first byte of the swap data to a fee. Previews do not include it.
- **Base.** A constant per book.
- **Gas burn (not a fee).** Each successful swap runs a loop of 1000 memory allocations and a penalized address runs another 500. Neither changes state. The cost is roughly 150-200k and 70-100k gas (estimated, not measured). Its purpose is inferred as a gas-denominated tax, since the paper does not mention it. This could be a misleading decompilation, but the loop is present in multiple decompiled contracts and in the bytecode. 

## CLOB complexity

$L$ is the number of levels per side ($L\le 19$) and $k$ the number of levels visited by a fill.

| Operation                                             | Storage writes  | Work         |
|-------------------------------------------------------|-----------------|--------------|
| Move the whole book to another price (`quote` update) | 1               | $O(1)$       |
| Replace both ladders (`updateBook`)                   | up to $2(L+1)$  | $O(L)$       |
| Fill inside one level                                 | 1 (accumulator) | $O(1)$       |
| Fill across levels                                    | 1 (accumulator) | $O(k)$ reads |
| Hide the best levels (engine deadline, no book write) | 1 (engine)      | $O(1)$       |

A fill does not decrement level liquidity. Each visited level costs constant arithmetic, and the only write is the accumulator of the traded side.

## Taker and maker accounting

- The book keeps two accumulators, `baseFlowAccumulator` and `quoteFlowAccumulator`. They are reset to 0 by `updateBook` and `reconfigure`.
- A swap with input $x$ on side $s$ increases that side's accumulator, with $f$ the `factor` in ppm:

$$A_s\ \leftarrow\ A_s + x\,\frac{f}{10^6}$$

- Consumed depth on side $s$ is the own flow minus the opposite flow converted at the anchor. Without netting it is the own flow:

$$D_s=\max\left(0,\ A_s-A_{\bar s}\,P_{\bar s\to s}\right)$$

- A walk on side $s$ skips the first levels while $D_s\ge$ liquidity, subtracting each from $D_s$. The first level with liquidity left offers only the remainder. Levels hidden by exclusion are skipped and not counted in $D_s$.
- Opposite flow therefore restores depth and same-direction flow moves later fills to worse levels (from the paper).
- There is no maker-side accounting. The treasury is the only counterparty.
- The input unit of the accumulators and the meaning of `factor` are inferred.

## Open questions

- Gas burn purpose is inferred and its gas cost is estimated.
- Flow accumulator unit (input vs output) and `factor` semantics are inferred. Verify via the storage diff of the accumulator slots in a swap tx and the on-chain `factor`.
- `Swap` event argument types are guessed.
- `BookParams` middle fields (`baseFee` ... `priorityFee`) are mapped from types and range checks only.
- `setDefaultFee` on a wrong block: revert or no-op is unverified.
- Engine constructor values, the pair-key hash encoding and the two-hop condition are inferred.
- Helper contracts (fingerprint, mode fee) are not decompiled. Selectors `0x1ed58fc8` and `0x4a89bec0` are raw `staticcall`s.
- Rounding: ceil is marked `TODO: round UP` in exact-out and the fee gross-up. Use libs for that.
- The paper does not specify the age curve, priority threshold, `factor`, accumulator reset or exact-out handling. Those come from the decompilation alone.

## References

- Paper: "Active Liquidity On Chain", arXiv 2609.38056: https://arxiv.org/html/2609.38056v1
- TesseraSwap: 0x55555522005BcAE1c2424D474BfD5ed477749E3e
- TesseraEngine: 0x31e99e05fee3dce580af777c3fd63ee1b3b40c17
- TesseraBook (implementation): 0x6d9dd143e42b6338f4f6a7c0c26d124658f641cb
- TesseraBookProxy (example): 0x4B963fB4A26f082D94f964FA3c2764821Cc06Bd4
