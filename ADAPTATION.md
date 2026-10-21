# Adaptation for the core launch (`evm_contracts`, Ethereum mainnet, third of four)

The four contracts, their order, their constructor arguments, fees, shares, bonds, windows, limits, recipients and
currencies are unchanged. No owner, pause, upgrade path, mint or fee was added. Every constructor stays nonpayable
and takes only addresses (YoloLockHub 1, CaseDesk 7, DisputeDesk 7, TaskVault 9 arguments). No contract contains
DELEGATECALL, CALLCODE or SELFDESTRUCT; the vault still forwards with a plain CALL.

Tests for every change: `test/LaunchAdaptation.t.sol`.

## 1. TaskVault constructor: no code check, no external call (audit finding 9e42cb3f, reproduced)

File: `src/TaskVault.sol` (constructor, `ask`, `_burn`).

The constructor required code at the burner (`burner_.code.length == 0 -> WrongWiring`) and called
`attestationChecker.registry()`. The launch rehearsal runs every constructor on an empty chain, where neither
contract of launch #2364 exists, so the fourth application failed and the launch would be parked. Reproduced:
deploying the four contracts in one call with the launch's static arguments on a bare chain reverted with
`WrongWiring()`.

Rule: "a constructor that calls another contract, or requires an address to have code, reverts there and parks the
launch. Take such values as arguments and check the live contract on first use." The brief's sentence
"make no external call except to the desks of this launch and AttestationChecker.registry()" is narrowed accordingly:
the only calls left in the constructor are the `wire` calls to the two desks of the same launch.

Both checks moved to first use, unchanged in what they refuse:
- `ask` (every swarm question) first checks `attestationChecker.registry() == registry`, else `WrongWiring`.
- `_burn` (every burn share) first checks that the burner has code, else `WrongWiring`.

Tests: `test_CoreLaunchDeploysOnAnEmptyChain` (the audit's reproduction, now passing),
`test_BurnerWithoutCodeRefusedAtFirstBurn`, `test_CheckerOfAnotherRegistryRefusedAtFirstAsk`,
`test_CheckerOfThisRegistryAsks`. Two tests in `test/Desks.t.sol` that expected the constructor to revert
(`test_BurnerMustHaveCode_DoerStakeMayBeLater`, `test_VaultRefusesCheckerOfAnotherRegistry`, renamed
`test_VaultDeploysWithCheckerOfAnotherRegistry`) now expect the deployment to succeed; the refusal is tested at first
use. `docs/MECHANICS.md` says where the burner is now checked.

## 2. Fail-safe read of the $YOLO add-on (audit finding 07f4b83b, reproduced)

File: `src/TaskVault.sol` (`_addon`).

`submitTerms` read `YoloSweetener.bonusOf` with a plain external call. A bound sweetener that reverts or returns no
data made every `submit` and `quoteSubmission` revert on every task, and the binding is once and forever. Reproduced
by etching a reverting `bonusOf` over the bound sweetener: both calls reverted. Now the read is a staticcall and a
failure or an answer that is not one word counts as no add-on, exactly as a failing YoloLockHub or DevPrices read
already does. Behaviour with a working sweetener is unchanged.

Test: `test_FailingAddonNeverBlocksASubmission` (reverting and silent sweetener; submission, acceptance and the
90% payout go through).

## 3. The bank pulls tokens only from the caller of the forwarded call (static analysis, arbitrary-send-erc20)

File: `src/TaskVault.sol` (`_caller`, `fallback`, `collectImd`, `collectBondPart`).

The previous submission was rejected for `arbitrary-send-erc20` at `collectBondPart`: `safeTransferFrom(from, ...)`
with `from` an argument (the verifier does not honour `slither-disable` comments). The desks always passed the user
the vault had appended to the forwarded call, so no exploit was reachable, but the vault relied on the desks for it.
The fallback now records its `msg.sender` in a transient slot `_caller` for the duration of the forwarded call (under
the existing lock, cleared afterwards); `collectImd` and `collectBondPart` refuse a `from` other than `_caller`
(`NotAuthorized`) and pull from `_caller`. Every legitimate path passes the same address as before, so behaviour is
unchanged; even a desk cannot pull from an account outside that account's own call.

Tests: `test_DeskCannotPullFromAnAccountOutsideItsCall`, `test_ForwardedCallsPullBondsFromTheirCaller`, and the
whole existing suite (every submission, dispute, appeal and swarm call runs through these two functions).

## 4. YoloLockHub checkpoints written through the mapping (static analysis, uninitialized-state)

File: `src/YoloLockHub.sol` (`_checkpoint`).

The analyzer reported `_history` as never initialized (high/high) because the writes went through a storage pointer.
`_checkpoint` now writes `_history[who]` directly; the stored values and the logic are identical
(`test/YoloLockHub.t.sol` unchanged and passing). The suppression comment was removed.

## Size margins

`test/review/ReviewLaunch.t.sol` pins the runtime margins under the 24,576-byte limit quoted in
`docs/LAUNCH-TASK.md`; both were updated to the new sizes: TaskVault 3,975 -> 3,635 bytes left (changes 1-3),
YoloLockHub 21,357 -> 21,279 (change 4). DisputeDesk (3,087 left) and CaseDesk (4,512 left) are unchanged. The vault
constructor makes one external call fewer, so the launch only gets cheaper under the 16,777,216 gas cap.

## Test fixed beside the changes

`test_BurnerMustHaveCode_DoerStakeMayBeLater` (`test/Desks.t.sol`) created its second task with proof type 0 (an X
post, which requires a screenshot) and submitted without one, so it stopped at `EvidenceRequired` before reaching
what it checks. That revert does not depend on the changes above. Since the test had to change for change 1 anyway,
its task now uses `PROOF_LINK`, like the generic tasks of `test/Base.t.sol`; the doer approves USDC for the bond's
"rew" part (3% of R in the reward currency), and the doer's credit is 90% plus that bond part back. What it checks (a hub without code means
no stake: the doer gets 90% and the treasury 10%) is unchanged.

## Audit findings that did not reproduce

None: both imported findings reproduced and are fixed above. The other static-analysis lines of the rejected run
(reentrancy-*, incorrect-equality, divide-before-multiply, arbitrary-send-eth to the caller's own refund or the
buyback wallet) were checked against the code: every state-changing entry is under the vault's single transient
lock, the equalities are zero checks or same-timestamp checks, and the division in `lock` is the documented whole-week
rounding. They are not defects and the code was left as it is.
