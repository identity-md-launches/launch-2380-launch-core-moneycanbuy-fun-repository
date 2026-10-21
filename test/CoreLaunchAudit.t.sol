// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {Base} from "./Base.t.sol";
import {TaskVault} from "../src/TaskVault.sol";
import {YoloLockHub} from "../src/YoloLockHub.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {ITaskVault} from "../src/interfaces/ITaskVault.sol";
import {AskTerms} from "../src/desks/DeskApi.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFT} from "./mocks/MockNFT.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import "../src/VaultTypes.sol";
import {rulesOf} from "./mocks/TaskRulesFixture.sol";

/// @dev Deploys two fresh desks and wires them in ONE call (one transaction), the way the launch does, and reports
///      what each wiring attempt answered. Transient storage only lives for that transaction.
contract WireProbe {
    function run(
        address registry,
        address imd,
        address usdc,
        address text,
        address builder,
        address yolo,
        address hub,
        address vp
    ) external returns (bytes4 wrongSlot, bytes4 wrongRegistry, bytes4 firstOk, bytes4 second) {
        CaseDesk c = new CaseDesk(registry, imd, usdc, text, builder, yolo, hub);
        DisputeDesk d = new DisputeDesk(registry, imd, usdc, text, vp, yolo, hub);
        // the case desk put in the dispute desk's slot: refused, and the refusal does not close the wiring (revert)
        wrongSlot = _try(address(c), abi.encodeCall(c.wire, (registry, imd, usdc, address(d), address(c))));
        wrongRegistry = _try(address(c), abi.encodeCall(c.wire, (address(0xBEEF), imd, usdc, address(c), address(d))));
        firstOk = _try(address(c), abi.encodeCall(c.wire, (registry, imd, usdc, address(c), address(d))));
        // once wired, never again, even in the same transaction
        second = _try(address(c), abi.encodeCall(c.wire, (registry, imd, usdc, address(c), address(d))));
    }

    function _try(address target, bytes memory data) private returns (bytes4 sel) {
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) return bytes4(0);
        if (ret.length < 4) return bytes4(0xffffffff);
        assembly {
            sel := mload(add(ret, 32))
        }
    }
}

/// @notice Adversarial review of the core launch (YoloLockHub, CaseDesk, DisputeDesk, TaskVault): the failure paths,
///         the boundaries of every window, and the exact money of each outcome as the brief states it.
contract CoreLaunchAuditTest is Base {
    uint256 internal constant R = 100e6; // a $100 USDC reward
    uint256 internal constant BOND_IMD = 0.5e18;

    function _usdcTask() internal returns (uint256) {
        return _create(author, address(usdc), R);
    }

    function _disputed() internal returns (uint256 t, uint256 s) {
        t = _usdcTask();
        s = _submit(doer, t);
        _dispute(dave, s);
    }

    // ============================================================ who may call what

    function test_DesksRefuseEveryoneButTheVaultAndEachOther() public {
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        vm.startPrank(dave);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.step(s);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.unwind(s);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.advanced(s);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.startVote(s, 1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.markAppealed(s);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.claimVoidSubmission(s);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.dropCaller(s);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.appealAsked(s, 0);
        vm.stopPrank();
        assertEq(uint8(_phase(s)), uint8(Phase.Review), "nothing moved");
    }

    /// A caller who appends somebody else's address (the vault's suffix) to a routed call is still refused.
    function test_SpoofedSuffixOnADeskIsRefused() public {
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        bytes memory data = abi.encodePacked(
            abi.encodeCall(disputeDesk.dispute, (s, DISPUTE_REASON, DISPUTER_PROOF, _noSwap())), dave, uint256(0)
        );
        vm.prank(dave);
        (bool ok, bytes memory ret) = address(disputeDesk).call(data);
        assertFalse(ok);
        assertEq(bytes4(ret), NotAuthorized.selector);
    }

    function test_VaultBankIsDesksOnly() public {
        uint256 t = _usdcTask();
        TaskVault v = TaskVault(payable(address(vault)));
        vm.startPrank(dave);
        vm.expectRevert(NotAuthorized.selector);
        v.credit(address(usdc), dave, 1);
        vm.expectRevert(NotAuthorized.selector);
        v.pay(address(usdc), dave, 1);
        vm.expectRevert(NotAuthorized.selector);
        v.burn(address(usdc), 1);
        vm.expectRevert(NotAuthorized.selector);
        v.addTreasury(address(usdc), 1);
        vm.expectRevert(NotAuthorized.selector);
        v.collectBondPart(author, 0, address(usdc), 1);
        vm.expectRevert(NotAuthorized.selector);
        v.collectImd(author, 0, 1, address(0), _noSwap());
        vm.expectRevert(NotAuthorized.selector);
        v.settleValue(dave, 0, 0);
        vm.expectRevert(NotAuthorized.selector);
        v.place(t, 99, false);
        vm.expectRevert(NotAuthorized.selector);
        v.closeSubmission(t, Outcome.Accepted, R);
        vm.expectRevert(NotAuthorized.selector);
        v.advance(t);
        AskTerms memory at;
        vm.expectRevert(NotAuthorized.selector);
        v.ask(at, "");
        vm.stopPrank();
        assertEq(vault.potOf(t), R);
        assertEq(vault.credits(address(usdc), dave), 0);
    }

    function test_DesksWireOnlyOnceOnlyInTheirSlotOnlyInTheDeploymentTransaction() public {
        WireProbe probe = new WireProbe();
        (bytes4 wrongSlot, bytes4 wrongReg, bytes4 firstOk, bytes4 second) = probe.run(
            address(registry),
            address(imd),
            address(usdc),
            address(vault.textRules()),
            address(0x1234),
            address(yolo),
            address(hub),
            address(votePower)
        );
        assertEq(wrongSlot, WrongWiring.selector, "a desk in the other slot");
        assertEq(wrongReg, WrongWiring.selector, "another registry");
        assertEq(firstOk, bytes4(0), "the first correct wiring");
        assertEq(second, WiringClosed.selector, "a second wiring");
        // the launch's desks, after their deployment transaction: closed for everyone
        vm.expectRevert(WiringClosed.selector);
        caseDesk.wire(address(registry), address(imd), address(usdc), address(caseDesk), address(disputeDesk));
        vm.expectRevert(WiringClosed.selector);
        disputeDesk.wire(address(registry), address(imd), address(usdc), address(caseDesk), address(disputeDesk));
        assertEq(caseDesk.vault(), address(vault));
        assertEq(disputeDesk.vault(), address(vault));
    }

    function test_UnknownSelectorAndStrayEthRefused() public {
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok);
        assertEq(bytes4(ret), UnknownFunction.selector);
        // ETH on a forwarded call that is not payable
        vm.deal(address(this), 1 ether);
        (ok, ret) = address(vault).call{value: 1}(abi.encodeCall(ITaskVault.claimDisputer, (1)));
        assertFalse(ok);
        assertEq(bytes4(ret), TaskVault.NotPayable.selector);
        // plain ETH (no receive)
        (ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
    }

    // ============================================================ creation, top-ups, the lock of the reward

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_MinimumPerCurrency(uint256 below, uint8 which) public {
        address[4] memory cs = [address(usdc), ETH, address(imd), address(yolo)];
        uint256[4] memory mins = [uint256(5e6), 0.002e18, 1e18, 1_000e18];
        uint256 i = which % 4;
        below = bound(below, 1, mins[i] - 1);
        uint64 dl = uint64(_now() + 1 days);
        vm.prank(author);
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask{value: cs[i] == ETH ? below : 0}(
            cs[i], below, dl, "Title", _rules(), 0, PROOF_LINK, "", _noSwap()
        );
        uint256 id = _createWithDeadline(author, cs[i], mins[i], dl);
        assertEq(vault.potOf(id), mins[i], "exactly the minimum is a task");
    }

    function _rules() internal pure returns (TaskRules memory r) {
        return rulesOf("ipfs://task-condition");
    }

    function test_NoRewardMaximumAndNoCreationFee() public {
        uint256 big = 500_000_000e6; // $500M in one task, more than anyone's balance in setUp
        usdc.mint(author, 2 * big);
        uint256 balBefore = usdc.balanceOf(author);
        uint256 t1 = _create(author, address(usdc), big);
        uint256 t2 = _create(author, address(usdc), big / 2 + 1);
        assertEq(balBefore - usdc.balanceOf(author), big + big / 2 + 1, "exactly the rewards, no fee");
        assertEq(vault.potOf(t1) + vault.potOf(t2), vault.liabilities(address(usdc)));
    }

    function test_DeadlineRequiredAndInTheFuture() public {
        vm.startPrank(author);
        vm.expectRevert(BadDeadline.selector);
        vault.createTask(address(usdc), R, 0, "Title", _rules(), 0, PROOF_LINK, "", _noSwap());
        vm.expectRevert(BadDeadline.selector);
        vault.createTask(address(usdc), R, uint64(_now()), "Title", _rules(), 0, PROOF_LINK, "", _noSwap());
        vm.stopPrank();
    }

    /// Nobody who put money in takes it back while the task is open: not before the deadline, not after it while a
    /// submission is still being judged.
    function test_RewardLockedWhileOpenEvenPastTheDeadline() public {
        uint256 t = _createWithDeadline(author, address(usdc), R, uint64(_now() + 2 days));
        _topUp(alice, t, 7e6);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        _warp(1 days);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(1 days + 1); // past the deadline, the submission is still being judged
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        vm.prank(bob);
        vm.expectRevert(DeadlinePassed.selector);
        vault.topUp(t, 1e6, _noSwap());
        assertEq(vault.potOf(t), R + 7e6);
    }

    function test_ExpiredRefundsExactlyOnce() public {
        uint256 t = _createWithDeadline(author, address(usdc), R, uint64(_now() + 1 days));
        _topUp(alice, t, 9e6);
        vm.warp(vault.getTask(t).deadline);
        uint256 a0 = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(alice) - a0, 9e6);
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        vm.prank(bob); // never put anything in
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        vm.prank(bob);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp(t, 1e6, _noSwap());
        vm.prank(doer);
        vm.expectRevert(TaskNotOpen.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
    }

    function test_SubmitGuards() public {
        uint256 t = _usdcTask();
        vm.startPrank(doer);
        vm.expectRevert(RewardChanged.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), R + 1, type(uint256).max, _noSwap());
        vm.expectRevert(CostAboveMax.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), R, 3e6 - 1, _noSwap());
        vm.expectRevert(TaskNotOpen.selector);
        vault.submit(t + 1, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        vm.stopPrank();
        assertEq(vault.submissionCount(), 0);
    }

    /// Bonds: 0.5 IMD + 3% of the author's own part (not of top-ups), never doubled for a queued submission.
    function test_DoerBondFromAuthorsPartNoDoubling() public {
        uint256 t = _usdcTask();
        _topUp(alice, t, 900e6); // a top-up does not raise the bond
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        uint256 s3 = _submit(doer3, t);
        for (uint256 i; i < 3; ++i) {
            Submission memory x = _sub([s1, s2, s3][i]);
            assertEq(x.bond.imd, BOND_IMD);
            assertEq(x.bond.rew, 3e6);
        }
        assertEq(uint8(_phase(s2)), uint8(Phase.Queued));
        Bond memory db = vault.quoteDisputeBond(s1);
        assertEq(db.imd, BOND_IMD);
        assertEq(db.rew, 1e6, "1% of the author's part");
    }

    // ============================================================ disputes and votes

    function test_DisputeWindowBoundaries() public {
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        vm.prank(doer);
        vm.expectRevert(DoerCannotDispute.selector);
        vault.dispute(s, DISPUTE_REASON, DISPUTER_PROOF, _noSwap());
        uint256 end = _sub(s).windowEnd;
        assertEq(end, _now() + 24 hours);
        vm.warp(end - 1);
        _dispute(author, s); // the author may dispute
        vm.prank(erin);
        vm.expectRevert(AlreadyDisputed.selector);
        vault.dispute(s, DISPUTE_REASON, DISPUTER_PROOF, _noSwap());
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));

        // a second task: exactly at the window end the next call settles it first
        uint256 t2 = _usdcTask();
        uint256 s2 = _submit(doer2, t2);
        vm.warp(_sub(s2).windowEnd);
        vm.prank(dave);
        vm.expectRevert(WrongPhase.selector);
        vault.dispute(s2, DISPUTE_REASON, DISPUTER_PROOF, _noSwap());
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
    }

    function test_VoteFailurePaths() public {
        (, uint256 s) = _disputed();
        address v3 = voters[3]; // ids 150..154
        uint256[] memory ids = new uint256[](0);
        vm.startPrank(v3);
        vm.expectRevert(NoTokens.selector);
        vault.vote(s, 1, v3, ids);
        ids = _ids(150, 1);
        vm.expectRevert(BadVote.selector);
        vault.vote(s, 0, v3, ids);
        vm.expectRevert(BadVote.selector);
        vault.vote(s, 3, v3, ids);
        vm.expectRevert(BadVote.selector);
        vault.vote(s, 1, address(0), ids);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 155));
        vault.vote(s, 1, v3, _ids(155, 1)); // voter4's NFT
        uint256[] memory dup = new uint256[](2);
        dup[0] = 151;
        dup[1] = 151;
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 151));
        vault.vote(s, 1, v3, dup);
        vault.vote(s, 1, v3, _ids(150, 2)); // accept with 150, 151
        vm.expectRevert(AlreadyVoted.selector);
        vault.vote(s, 2, v3, _ids(152, 1)); // the side never changes
        vault.vote(s, 1, v3, _ids(152, 1)); // more NFTs on the same side
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 150));
        vault.vote(s, 1, v3, _ids(150, 1));
        // an NFT passed on after its vote does not vote again in this dispute
        MockNFT(address(nft)).transferFrom(v3, voters[4], 150);
        vm.stopPrank();
        vm.prank(voters[4]);
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 150));
        vault.vote(s, 2, voters[4], _ids(150, 1));
        (uint256 acc, uint256 rej) = vault.votesOf(s, v3);
        assertEq(acc, 3);
        assertEq(rej, 0);
        // the vote end is exclusive
        vm.warp(_sub(s).voteEnd);
        vm.prank(voters[4]);
        vm.expectRevert(WrongPhase.selector);
        vault.vote(s, 2, voters[4], _ids(155, 2));
    }

    function test_VoteBeforeAnyDisputeRefused() public {
        uint256 s = _submit(doer, _usdcTask());
        vm.prank(voters[3]);
        vm.expectRevert(WrongPhase.selector);
        vault.vote(s, 1, voters[3], _ids(150, 1));
    }

    /// Lead 19 does not decide at once; lead 20 does; at the end lead 9 does not, lead 10 does.
    function test_DecisionThresholds() public {
        (, uint256 s) = _disputed();
        address one = _holder("one", 1);
        _voteAs(s, one, 2); // reject 1
        _vote(s, 1, 1, 120, 20); // accept 20: lead 19
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "lead 19 is not instant");
        address two = _holder("two", 1);
        _voteAs(s, two, 1); // lead 20
        assertEq(uint8(_phase(s)), uint8(Phase.Decided), "lead 20 decides at once");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Accept));

        (, uint256 s2) = _disputed();
        address three = _holder("three", 1);
        _voteAs(s2, three, 1); // accept 1
        _vote(s2, 2, 2, 140, 10); // reject 10: lead 9
        _endVote(s2);
        assertEq(uint8(_phase(s2)), uint8(Phase.NoDecision), "lead 9 at the end");

        (, uint256 s3) = _disputed();
        _vote(s3, 2, 2, 140, 10); // reject 10: lead 10
        _endVote(s3);
        assertEq(uint8(_phase(s3)), uint8(Phase.Decided), "lead 10 at the end");
        assertEq(uint8(_sub(s3).nftDecision), uint8(Verdict.Reject));
    }

    // ============================================================ money of each outcome

    /// Accepted without a dispute: 90% to the doer, 10% to the treasury (no stake), every bond back.
    function test_Money_AcceptedQuietly() public {
        uint256 t = _usdcTask();
        _topUp(alice, t, 50e6);
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 135e6 + 3e6, "90% of the whole pot + rew bond");
        assertEq(vault.credits(address(imd), doer), BOND_IMD);
        assertEq(vault.treasuryPot(address(usdc)), 15e6);
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        _claimEverythingAndCheck();
    }

    /// Instant NFT acceptance, no appeal: the doer's 90%; the NFT 5% to the correct votes; the disputer's bond
    /// half to the doer, half to the correct votes.
    function test_Money_NftAcceptsRight() public {
        (uint256 t, uint256 s) = _disputed();
        _vote(s, 1, 1, 120, 20);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6 + 0.5e6);
        assertEq(vault.credits(address(imd), doer), BOND_IMD + 0.25e18);
        assertEq(vault.treasuryPot(address(usdc)), 5e6);
        uint256 u0 = usdc.balanceOf(voters[1]);
        uint256 i0 = imd.balanceOf(voters[1]);
        vault.claimVoterReward(s, voters[1]);
        assertEq(usdc.balanceOf(voters[1]) - u0, 5e6 + 0.5e6);
        assertEq(imd.balanceOf(voters[1]) - i0, 0.25e18);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[1]);
        uint256 du = usdc.balanceOf(dave);
        uint256 di = imd.balanceOf(dave);
        vm.prank(dave);
        vault.claimDisputer(s); // the losing disputer gets nothing back
        assertEq(usdc.balanceOf(dave), du);
        assertEq(imd.balanceOf(dave), di);
        _claimEverythingAndCheck();
    }

    /// NFT rejects at the end, no appeal: the reward stays in the task; the doer's bond half to the disputer, half to
    /// the correct votes; the disputer's own bond back.
    function test_Money_NftRejectsRight_RewardStays() public {
        (uint256 t, uint256 s) = _disputed();
        _vote(s, 2, 2, 140, 10);
        _endVote(s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(vault.potOf(t), R, "the reward stays in the task");
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        uint256 u0 = usdc.balanceOf(dave);
        uint256 i0 = imd.balanceOf(dave);
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(usdc.balanceOf(dave) - u0, 1e6 + 1.5e6);
        assertEq(imd.balanceOf(dave) - i0, BOND_IMD + 0.25e18);
        u0 = usdc.balanceOf(voters[2]);
        vault.claimVoterReward(s, voters[2]);
        assertEq(usdc.balanceOf(voters[2]) - u0, 1.5e6, "no reward fee on a rejection");
        assertEq(vault.credits(address(usdc), doer), 0);
        assertEq(vault.treasuryPot(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// NFT undecided and nobody calls the swarm: accepted, the disputer's whole bond goes to the doer.
    function test_Money_UndecidedUncalled_DisputerBondToDoer() public {
        (uint256 t, uint256 s) = _disputed();
        _endVote(s); // no vote at all
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6 + 1e6);
        assertEq(vault.credits(address(imd), doer), 2 * BOND_IMD);
        assertEq(vault.treasuryPot(address(usdc)), 10e6, "nobody decided: the NFT 5% to the treasury");
        _claimEverythingAndCheck();
    }

    /// At most three swarm questions per submission; after the third silence it ends as if nobody had called. The
    /// caller's bond comes back after every silence, the fees stay paid.
    function test_ThreeSilencesEndAsIfUncalled() public {
        (uint256 t, uint256 s) = _disputed();
        _endVote(s);
        uint256 paid0 = imd.balanceOf(swarmPayee);
        for (uint256 i; i < 3; ++i) {
            assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
            _callSwarm(erin, s);
            assertEq(uint8(_phase(s)), uint8(Phase.Asked));
            _silent(s);
            vault.poke(t);
        }
        assertEq(uint8(_phase(s)), uint8(Phase.Final));
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(imd.balanceOf(swarmPayee) - paid0, 3 * PRICE, "three fees spent");
        assertEq(vault.credits(address(imd), erin), 3 * BOND_IMD, "the caller's bond back three times");
        assertEq(vault.credits(address(usdc), erin), 3 * 1e6);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6 + 1e6, "the disputer's bond to the doer");
        vm.prank(erin);
        vm.expectRevert(WrongPhase.selector);
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        _claimEverythingAndCheck();
    }

    /// The swarm overturns the NFT on appeal: the NFT was wrong, so the doer's bond goes wholly to the winners
    /// (disputer and appellant pro rata) and the votes get nothing.
    function test_Money_SwarmOverturnsNft() public {
        (uint256 t, uint256 s) = _disputed();
        _vote(s, 1, 1, 120, 20); // NFT accepts
        _appeal(erin, s);
        _askAppealSwarm(s);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[1]);
        assertEq(vault.potOf(t), R);
        _claimEverythingAndCheck();
    }

    // ============================================================ cancellation

    function test_CancelOnlyDevAndOnlyOpen() public {
        uint256 t = _usdcTask();
        address[3] memory others = [author, multisig, treasury];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(NotAuthorized.selector);
            vault.cancelTask(t);
        }
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t + 7); // no such task
        uint256 s = _submit(doer, t);
        _warp(24 hours); // the review ran out: the cancel call settles it first
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Review), "the reverted call left nothing behind");
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
    }

    /// Cancelled while the swarm is asked: everybody gets back what they put in except the swarm fee already paid;
    /// a late answer changes nothing; the dev wallet gets nothing.
    function test_CancelWhileAsked_EverybodyRefunded() public {
        uint256 t = _usdcTask();
        _topUp(alice, t, 20e6);
        uint256 s = _submit(doer, t);
        uint256 q = _submit(doer2, t); // queued
        _dispute(dave, s);
        _vote(s, 3, 1, 150, 5);
        _endVote(s);
        _callSwarm(erin, s);
        uint256 dev0u = usdc.balanceOf(devWallet);
        uint256 dev0i = imd.balanceOf(devWallet);
        vm.prank(devWallet);
        vault.cancelTask(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Unwound));
        // a late answer for the cancelled submission
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Unwound));
        assertEq(vault.credits(address(usdc), doer), 3e6);
        assertEq(vault.credits(address(imd), doer), BOND_IMD);
        assertEq(vault.credits(address(imd), erin), BOND_IMD, "the caller's bond, not the fee");
        assertEq(vault.credits(address(usdc), erin), 1e6);
        uint256 d0 = usdc.balanceOf(dave);
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(usdc.balanceOf(dave) - d0, 1e6);
        uint256 q0 = usdc.balanceOf(doer2);
        vault.claimVoidSubmission(q);
        assertEq(usdc.balanceOf(doer2) - q0, 3e6);
        uint256 a0 = usdc.balanceOf(author);
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(author) - a0, R);
        a0 = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(alice) - a0, 20e6);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[3]);
        assertEq(vault.treasuryPot(address(usdc)), 0);
        assertEq(usdc.balanceOf(devWallet), dev0u);
        assertEq(imd.balanceOf(devWallet), dev0i);
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t);
        _claimEverythingAndCheck();
    }

    // ============================================================ the doer stake

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_StakeBonusSplit(uint256 amount, uint8 weeks_) public {
        amount = bound(amount, 1e18, 3_000_000e18);
        weeks_ = uint8(bound(weeks_, 1, 52));
        vm.prank(doer);
        hub.lock(amount, weeks_);
        uint256 power = amount * weeks_ / 52;
        _warp(1);
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        uint256 inYolo = 1_000_000e18; // $100 at $0.0001
        uint256 bps = power >= inYolo ? 400 : 400 * power / inYolo;
        assertEq(_sub(s).stakeBps, bps, "4% x min(1, power / reward in YOLO)");
        uint256 w0 = usdc.balanceOf(buybackWallet);
        _warp(24 hours);
        vault.poke(t);
        uint256 bonus = R * bps / 10_000;
        uint256 half = (5e6 - bonus) / 2;
        assertEq(vault.credits(address(usdc), doer), 90e6 + bonus + 3e6);
        assertEq(usdc.balanceOf(buybackWallet) - w0, half + 5e6, "half the rest + the NFT 5% nobody earned");
        assertEq(vault.treasuryPot(address(usdc)), 5e6 - bonus - half);
        _assertSolvent();
    }

    function test_StakeLockedInTheSameSecondDoesNotCount() public {
        uint256 t = _usdcTask();
        vm.prank(doer);
        hub.lock(10_000_000e18, 52);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 0);
        assertFalse(_sub(s).staked);
    }

    function test_StakeEndedBeforePayoutPaysNoBonus() public {
        vm.prank(doer);
        hub.lock(60_000_000e18, 1); // 1 week: power 60M / 52 > the 1M of the reward
        _warp(7 days - 1 hours);
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 400);
        _warp(24 hours); // the lock ended during the review
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
    }

    function test_StakeWithdrawnAndRelockedBeforePayoutPaysNoBonus() public {
        vm.prank(doer);
        hub.lock(60_000_000e18, 1); // 1 week: power 60M / 52 > the 1M of the reward
        _warp(7 days - 1 hours);
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        _warp(2 hours);
        vm.startPrank(doer);
        hub.withdraw();
        hub.lock(60_000_000e18, 52); // a new lock: not the one of the submission
        vm.stopPrank();
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6);
    }

    /// A hub that fails never blocks a submission or a payout.
    function test_FailingHubCountsAsNoStake() public {
        vm.prank(doer);
        hub.lock(10_000_000e18, 52);
        _warp(1);
        uint256 t = _usdcTask();
        vm.etch(address(hub), hex"fe");
        uint256 s = _submit(doer, t);
        assertFalse(_sub(s).staked);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6);
    }

    function test_HubTermsAndWithdraw() public {
        vm.startPrank(doer);
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.lock(0, 0);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(1e18, 53);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(1e18, 0); // no running lock: a term is needed
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.lock(0, 4); // a term without an amount
        hub.lock(52e18, 4);
        assertEq(hub.power(doer), 4e18);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(0, 3); // only longer
        vm.expectRevert(abi.encodeWithSelector(YoloLockHub.LockRunning.selector, uint64(_now() + 4 weeks)));
        hub.withdraw();
        vm.stopPrank();
        _warp(2 weeks);
        vm.prank(doer);
        hub.lock(0, 10); // extension: amount x weeks left / 52
        assertEq(hub.power(doer), 10e18);
        _warp(10 weeks);
        assertEq(hub.power(doer), 0, "0 once the lock ended");
        uint256 b0 = yolo.balanceOf(doer);
        vm.prank(doer);
        hub.withdraw();
        assertEq(yolo.balanceOf(doer) - b0, 52e18);
        vm.prank(doer);
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.withdraw();
    }
}

// ================================================================ invariants: the vault with cancellations

/// @dev Drives one USDC economy with cancellations by the dev wallet mixed in (the base invariant suite has none):
///      create, top up, submit, dispute, vote, cancel, time, claims and withdrawals in random order.
contract CancelHandler is CommonBase, StdCheats, StdUtils {
    ITaskVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal imd;
    MockIntake internal intake;
    address internal dev;
    address[] internal people;
    address[] internal nftVoters;
    mapping(address => uint256[]) internal idsOf;

    uint256[] public tasks;
    mapping(uint256 => mapping(address => uint256)) public putIn; // task => who => USDC put into the reward
    mapping(uint256 => mapping(address => uint256)) public tookBack; // task => who => withdrawContribution
    mapping(uint256 => uint8) public seenStatus; // the last status seen (a final one never changes)
    bool public reopened;
    uint256 public cancels;

    constructor(
        ITaskVault v,
        MockERC20 u,
        MockERC20 i,
        MockIntake in_,
        address dev_,
        address[] memory people_,
        address[] memory voters_,
        uint256[][] memory ids_
    ) {
        vault = v;
        usdc = u;
        imd = i;
        intake = in_;
        dev = dev_;
        people = people_;
        nftVoters = voters_;
        for (uint256 k; k < voters_.length; ++k) {
            idsOf[voters_[k]] = ids_[k];
        }
    }

    function taskCount() external view returns (uint256) {
        return tasks.length;
    }

    function _who(uint256 seed) internal view returns (address) {
        return people[seed % people.length];
    }

    function _task(uint256 seed) internal view returns (uint256) {
        return tasks.length == 0 ? 0 : tasks[seed % tasks.length];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _rules() internal pure returns (TaskRules memory r) {
        return rulesOf("ipfs://task-condition");
    }

    function create(uint256 seed, uint256 amount) external {
        address who = _who(seed);
        amount = bound(amount, 5e6, 10_000e6);
        ImdPay memory none;
        vm.prank(who);
        uint256 id =
            vault.createTask(address(usdc), amount, uint64(_now() + 3 days), "T", _rules(), 0, PROOF_LINK, "", none);
        tasks.push(id);
        putIn[id][who] += amount;
        seenStatus[id] = uint8(TaskStatus.Open);
    }

    function topUp(uint256 seed, uint256 amount) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        address who = _who(seed >> 8);
        amount = bound(amount, 1, 5_000e6);
        ImdPay memory none;
        vm.prank(who);
        try vault.topUp(t, amount, none) {
            putIn[t][who] += amount;
        } catch {}
        _see(t);
    }

    function submit(uint256 seed) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.submit(t, "https://x.com/doer/status/1", Evidence("", ""), 0, type(uint256).max, none) {} catch {}
        _see(t);
    }

    function dispute(uint256 seed) external {
        uint256 n = vault.submissionCount();
        if (n == 0) return;
        uint256 s = seed % n + 1;
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.dispute(s, "ipfs://reason", "ipfs://reason-proof", none) {} catch {}
    }

    function vote(uint256 seed, bool accept) external {
        uint256 n = vault.submissionCount();
        if (n == 0) return;
        uint256 s = seed % n + 1;
        address v = nftVoters[(seed >> 8) % nftVoters.length];
        vm.prank(v);
        try vault.vote(s, accept ? 1 : 2, v, idsOf[v]) {} catch {}
    }

    function cancel(uint256 seed) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        vm.prank(dev);
        try vault.cancelTask(t) {
            ++cancels;
        } catch {}
        _see(t);
    }

    function warp(uint256 dt) external {
        vm.warp(_now() + bound(dt, 1, 2 days));
    }

    function poke(uint256 seed) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        vault.poke(t);
        _see(t);
    }

    function withdrawContribution(uint256 seed) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        address who = _who(seed >> 8);
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        try vault.withdrawContribution(t) {
            tookBack[t][who] += usdc.balanceOf(who) - before;
        } catch {}
        _see(t);
    }

    function claims(uint256 seed) external {
        uint256 n = vault.submissionCount();
        if (n == 0) return;
        uint256 s = seed % n + 1;
        address who = _who(seed >> 8);
        vm.startPrank(who);
        try vault.claimDisputer(s) {} catch {}
        try vault.claimVoidSubmission(s) {} catch {}
        try vault.withdraw(address(usdc)) {} catch {}
        try vault.withdraw(address(imd)) {} catch {}
        vm.stopPrank();
        try vault.claimVoterReward(s, nftVoters[(seed >> 16) % nftVoters.length]) {} catch {}
    }

    function _see(uint256 t) internal {
        uint8 st = uint8(vault.getTask(t).status);
        uint8 was = seenStatus[t];
        if (was != uint8(TaskStatus.Open) && st != was) reopened = true;
        seenStatus[t] = st;
    }

    function peopleCount() external view returns (uint256) {
        return people.length;
    }

    function person(uint256 i) external view returns (address) {
        return people[i];
    }
}

contract CancelInvariantTest is Base {
    CancelHandler internal h;

    function setUp() public override {
        super.setUp();
        address[] memory ps = new address[](6);
        ps[0] = author;
        ps[1] = alice;
        ps[2] = bob;
        ps[3] = doer;
        ps[4] = doer2;
        ps[5] = dave;
        address[] memory vs = new address[](3);
        uint256[][] memory ids = new uint256[][](3);
        for (uint256 i; i < 3; ++i) {
            vs[i] = voters[i + 1];
            ids[i] = held[voters[i + 1]];
        }
        h = new CancelHandler(vault, usdc, imd, intake, devWallet, ps, vs, ids);
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_SolventAndRefundsBounded() public view {
        _assertSolvent();
        assertFalse(h.reopened(), "a final task changed its status");
        uint256 n = h.taskCount();
        for (uint256 i; i < n; ++i) {
            uint256 t = h.tasks(i);
            Task memory tk = vault.getTask(t);
            uint256 activeSum;
            for (uint256 p; p < h.peopleCount(); ++p) {
                address who = h.person(p);
                uint256 active = vault.getContribution(t, who).active;
                activeSum += active;
                // what is left plus what was taken back is exactly what was put in, until an acceptance
                if (tk.status != TaskStatus.Completed) {
                    assertEq(active + h.tookBack(t, who), h.putIn(t, who), "contribution != put in - taken back");
                }
                assertLe(h.tookBack(t, who), h.putIn(t, who), "took back more than put in");
            }
            if (tk.status == TaskStatus.Completed) assertEq(tk.pot, 0, "a completed task keeps a pot");
            else assertEq(tk.pot, activeSum, "pot != sum of the contributions");
            if (tk.status == TaskStatus.Open) {
                for (uint256 p; p < h.peopleCount(); ++p) {
                    assertEq(h.tookBack(t, h.person(p)), 0, "money left an open task");
                }
            }
        }
    }
}

// ================================================================ invariants: YoloLockHub

contract HubHandler is CommonBase, StdCheats, StdUtils {
    YoloLockHub public hub;
    MockERC20 public yolo;
    address[] public actors;
    mapping(address => uint256) public locked;
    mapping(address => uint256) public withdrawn;
    uint256 public totalIn;
    uint256 public totalOut;

    constructor(YoloLockHub h, MockERC20 y, address[] memory a) {
        hub = h;
        yolo = y;
        actors = a;
    }

    function count() external view returns (uint256) {
        return actors.length;
    }

    function lock(uint256 seed, uint256 add, uint256 weeks_) external {
        address who = actors[seed % actors.length];
        add = bound(add, 0, 1_000_000e18);
        weeks_ = bound(weeks_, 0, 53);
        yolo.mint(who, add);
        vm.startPrank(who);
        yolo.approve(address(hub), add);
        try hub.lock(add, weeks_) {
            locked[who] += add;
            totalIn += add;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 seed) external {
        address who = actors[seed % actors.length];
        uint256 b = yolo.balanceOf(who);
        vm.prank(who);
        try hub.withdraw() {
            uint256 got = yolo.balanceOf(who) - b;
            withdrawn[who] += got;
            totalOut += got;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1, 20 weeks));
    }
}

contract HubInvariantTest is Test {
    YoloLockHub internal hub;
    MockERC20 internal yolo;
    HubHandler internal h;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);
        yolo = new MockERC20("YOLO", "YOLO", 18);
        hub = new YoloLockHub(address(yolo));
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(0xA11CE + i)));
        }
        h = new HubHandler(hub, yolo, actors);
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 80
    function invariant_HubHoldsEveryLockAndPowerBounded() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            address who = actors[i];
            (uint96 amount, uint64 end,) = hub.locks(who);
            sum += amount;
            uint256 p = hub.power(who);
            assertLe(p, amount, "power above the amount");
            if (end <= vm.getBlockTimestamp()) assertEq(p, 0, "power of an ended lock");
            assertLe(end, vm.getBlockTimestamp() + 52 weeks, "a lock longer than 52 weeks");
            assertLe(h.withdrawn(who), h.locked(who), "withdrew more than locked");
            assertEq(h.locked(who) - h.withdrawn(who), amount, "lock amount != locked - withdrawn");
        }
        assertEq(yolo.balanceOf(address(hub)), sum, "hub balance != sum of the locks");
        assertEq(h.totalIn() - h.totalOut(), sum);
    }
}
