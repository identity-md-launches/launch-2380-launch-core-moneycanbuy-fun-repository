// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Deploys the four contracts of the core launch in ONE call, as ProjectFactory.launchContracts does (the desks
///      accept `wire` only inside the transaction that deployed them), with the launch's own static arguments.
contract CoreLaunchProbe {
    function deployAll(
        address registry,
        address imd,
        address usdc,
        address textRules,
        address questionBuilder,
        address yolo,
        address votePower,
        address attestationChecker,
        address burner
    ) external returns (address vault) {
        YoloLockHub hub = new YoloLockHub(yolo);
        CaseDesk caseDesk = new CaseDesk(registry, imd, usdc, textRules, questionBuilder, yolo, address(hub));
        DisputeDesk disputeDesk = new DisputeDesk(registry, imd, usdc, textRules, votePower, yolo, address(hub));
        vault = address(
            new TaskVault(
                registry,
                imd,
                usdc,
                yolo,
                attestationChecker,
                textRules,
                address(caseDesk),
                address(disputeDesk),
                burner
            )
        );
    }
}

/// @dev A sweetener whose `bonusOf` reverts (or answers nothing).
contract BrokenAddon {
    bool public silent;

    function setSilent(bool s) external {
        silent = s;
    }

    function bonusOf(uint256) external view {
        if (!silent) revert("broken");
    }
}

/// @notice The changes of ADAPTATION.md, one test each.
contract LaunchAdaptationTest is Base {
    address internal stranger = makeAddr("stranger");

    // the static constructor arguments of the core launch (launch #2364 addresses, mainnet)
    address constant L_REGISTRY = 0x25576E455A87B92836EA901E89e6b26e59306BE9;
    address constant L_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant L_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant L_TEXT_RULES = 0xAdfe6bd2C17dB514241e1A9B3342F88876073B7F;
    address constant L_QUESTION_BUILDER = 0x6b491127d1a6507363FEEcC3420153AA77873881;
    address constant L_YOLO = 0x49E55A87AA4bB0d2fd58fDCf1A31c9612DE015dc;
    address constant L_VOTE_POWER = 0xEac6b7525f184ADA392601ed1Ce197fbC9F809b8;
    address constant L_CHECKER = 0x88eB0e6A38A8eA9A291697cf2420EFbA6EE0CCf9;
    address constant L_BURNER = 0xbf6838E27F82754443724006D127a130B9dd9E0A;

    // ------------------------------------------------------------------ finding 9e42cb3f: empty-chain constructors

    /// @notice The launch rehearsal runs the constructors on a chain where no contract of launch #2364 exists.
    function test_CoreLaunchDeploysOnAnEmptyChain() public {
        vm.chainId(1);
        assertEq(L_BURNER.code.length, 0);
        assertEq(L_CHECKER.code.length, 0);
        CoreLaunchProbe probe = new CoreLaunchProbe();
        TaskVault v = TaskVault(
            payable(probe.deployAll(
                    L_REGISTRY,
                    L_IMD,
                    L_USDC,
                    L_TEXT_RULES,
                    L_QUESTION_BUILDER,
                    L_YOLO,
                    L_VOTE_POWER,
                    L_CHECKER,
                    L_BURNER
                ))
        );
        assertGt(address(v).code.length, 0);
        assertEq(v.burner(), L_BURNER);
        assertEq(address(v.attestationChecker()), L_CHECKER);
        assertEq(v.registry(), L_REGISTRY);
    }

    function _freshVault(address checker, address burner_) internal returns (ITaskVault v) {
        TextRules text = new TextRules();
        address r = address(registry);
        CaseDesk cd = new CaseDesk(
            r,
            address(imd),
            address(usdc),
            address(text),
            address(new SwarmQuestionBuilder()),
            address(yolo),
            address(hub)
        );
        DisputeDesk dd = new DisputeDesk(
            r, address(imd), address(usdc), address(text), address(votePower), address(yolo), address(hub)
        );
        v = ITaskVault(
            address(
                new TaskVault(
                    r,
                    address(imd),
                    address(usdc),
                    address(yolo),
                    checker,
                    address(text),
                    address(cd),
                    address(dd),
                    burner_
                )
            )
        );
        vault = v; // the Base helpers act on `vault`
        _fund(author);
        _fund(doer);
        _fund(alice);
        _fund(bob);
    }

    /// @notice The burner's code, no longer required by the constructor, is checked at the first burn: a vault with a
    ///         code-less burner refuses to settle (WrongWiring) instead of sending burn shares to an empty address.
    function test_BurnerWithoutCodeRefusedAtFirstBurn() public {
        _freshVault(address(new AttestationChecker(address(registry))), stranger);
        // a $YOLO reward: the treasury's share of it is always burned, staked doer or not
        uint256 t = _create(author, address(yolo), 10_000e18);
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vm.expectRevert(WrongWiring.selector);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.None));
    }

    /// @notice The checker's registry, no longer read by the constructor, is checked at the first swarm question.
    function test_CheckerOfAnotherRegistryRefusedAtFirstAsk() public {
        _freshVault(address(new AttestationChecker(stranger)), address(burner));
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(alice, s);
        _endVote(s); // nobody voted: the NFT did not decide
        vm.prank(bob);
        vm.expectRevert(WrongWiring.selector);
        vault.callSwarm{value: ETH_BOND_HEADROOM}(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
    }

    /// @notice With the right checker the same path asks the swarm (the check costs nothing else).
    function test_CheckerOfThisRegistryAsks() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(alice, s);
        _endVote(s);
        _callSwarm(bob, s);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
    }

    // ------------------------------------------------------------------ finding 07f4b83b: fail-safe add-on read

    /// @notice A bound sweetener that reverts or answers nothing counts as no add-on: quotes and submissions go on.
    function test_FailingAddonNeverBlocksASubmission() public {
        uint256 t = _create(author, address(usdc), 100e6);
        BrokenAddon broken = new BrokenAddon();
        vm.etch(address(sweetener), address(broken).code);
        vault.quoteSubmission(t);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).taskId, t);
        uint256 t2 = _create(author, address(usdc), 100e6);
        BrokenAddon(address(sweetener)).setSilent(true); // returns no data
        vault.quoteSubmission(t2);
        uint256 s2 = _submit(bob, t2);
        assertEq(_sub(s2).taskId, t2);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // 90% of the reward and the doer bond's rew part back (no stake, the add-on counted as 0)
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(vault.credits(address(usdc), doer), 90e6 + _bondOf(100e6));
    }

    // ------------------------------------------------------------------ arbitrary-from: bank pulls only from the caller

    /// @notice Outside a forwarded call of that user, not even a desk can make the vault pull a user's tokens.
    function test_DeskCannotPullFromAnAccountOutsideItsCall() public {
        TaskVault v = TaskVault(payable(address(vault)));
        ImdPay memory none;
        uint256 balance = usdc.balanceOf(alice);
        vm.startPrank(address(caseDesk));
        vm.expectRevert(NotAuthorized.selector);
        v.collectBondPart(alice, 0, address(usdc), 1e6);
        vm.expectRevert(NotAuthorized.selector);
        v.collectImd(alice, 0, 1e18, address(0), none);
        vm.stopPrank();
        vm.prank(address(disputeDesk));
        vm.expectRevert(NotAuthorized.selector);
        v.collectBondPart(alice, 0, address(usdc), 1e6);
        assertEq(usdc.balanceOf(alice), balance);
    }

    /// @notice The forwarded calls still pull their bonds from their own caller (USDC "rew" part, IMD fixed part).
    function test_ForwardedCallsPullBondsFromTheirCaller() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 usdcBefore = usdc.balanceOf(doer);
        uint256 imdBefore = imd.balanceOf(doer);
        uint256 s = _submit(doer, t);
        assertEq(usdcBefore - usdc.balanceOf(doer), _bondOf(100e6));
        assertEq(imdBefore - imd.balanceOf(doer), _fixedBond());
        uint256 aliceUsdc = usdc.balanceOf(alice);
        _dispute(alice, s);
        assertEq(aliceUsdc - usdc.balanceOf(alice), _dBondOf(100e6));
        _assertSolvent();
    }
}
