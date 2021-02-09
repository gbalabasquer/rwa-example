pragma solidity >=0.5.12;

import "ds-test/test.sol";
import "ds-token/token.sol";
import "ds-math/math.sol";

import {Vat} from "dss/vat.sol";
import {Cat} from 'dss/cat.sol';
import {Vow} from 'dss/vow.sol';

import {Spotter} from "dss/spot.sol";
import {Flopper} from 'dss/flop.sol';
import {Flapper} from 'dss/flap.sol';

import {DaiJoin} from 'dss/join.sol';
import {AuthGemJoin} from "dss-gem-joins/join-auth.sol";

import {RwaToken} from "../RwaToken.sol";
import {RwaConduit, RwaRoutingConduit} from "../RwaConduit.sol";
import {RwaLiquidationOracle} from "../RwaLiquidationOracle.sol";
import {RwaUrn} from "../RwaUrn.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract RwaUltimateRecipient {
    DSToken dai;
    constructor(DSToken dai_) public {
        dai = dai_;
    }
    function transfer(address who, uint256 wad) public {
        dai.transfer(who, wad);
    }
}

contract TryCaller {
    function try_call(address addr, bytes calldata data) external returns (bool) {
        bytes memory _data = data;
        assembly {
            let ok := call(gas(), addr, 0, add(_data, 0x20), mload(_data), 0, 0)
            let free := mload(0x40)
            mstore(free, ok)
            mstore(0x40, add(free, 32))
            revert(free, 32)
        }
    }
}

contract RwaUser is TryCaller {
    RwaUrn urn;
    RwaRoutingConduit outC;
    RwaConduit inC;

    constructor(RwaUrn urn_, RwaRoutingConduit outC_, RwaConduit inC_) public {
        urn = urn_;
        outC = outC_;
        inC = inC_;
    }

    function approve(RwaToken tok, address who, uint256 wad) public {
        tok.approve(who, wad);
    }
    function pick(address who) public {
        outC.pick(who);
    }
    function lock(uint256 wad) public {
        urn.lock(wad);
    }
    function free(uint256 wad) public {
        urn.free(wad);
    }
    function draw(uint256 wad) public {
        urn.draw(wad);
    }
    function wipe(uint256 wad) public {
        urn.wipe(wad);
    }
    function can_pick(address who) public returns (bool) {
        string memory sig = "pick(address)";
        bytes memory data = abi.encodeWithSignature(sig, who);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", address(outC), data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
    function can_draw(uint256 wad) public returns (bool) {
        string memory sig = "draw(uint256)";
        bytes memory data = abi.encodeWithSignature(sig, wad);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", address(urn), data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
}

contract TryPusher is TryCaller {
    function can_push(address wat) public returns (bool) {
        string memory sig = "push()";
        bytes memory data = abi.encodeWithSignature(sig);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", wat, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
    }
}

contract RwaExampleTest is DSTest, DSMath, TryPusher {
    Hevm hevm;

    DSToken gov;
    DSToken dai;
    RwaToken rwa;

    Vat vat;
    Vow vow;
    Cat cat;
    Spotter spot;

    Flapper flap;
    Flopper flop;

    DaiJoin daiJoin;
    AuthGemJoin gemJoin;

    RwaLiquidationOracle oracle;
    RwaUrn urn;

    RwaRoutingConduit outConduit;
    RwaConduit inConduit;

    RwaUser usr;
    RwaUltimateRecipient rec;

    // debt ceiling of 400 dai
    uint256 ceiling = 400 ether;
    bytes32 doc = keccak256(abi.encode("Please sign on the dotted line."));

    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }
    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        // deploy governance token
        gov = new DSToken('GOV');
        gov.mint(100 ether);

        // deploy rwa token
        rwa = new RwaToken();

        // standard Vat setup
        vat = new Vat();

        spot = new Spotter(address(vat));
        vat.rely(address(spot));

        flap = new Flapper(address(vat), address(gov));
        flop = new Flopper(address(vat), address(gov));

        vow = new Vow(address(vat), address(flap), address(flop));
        flap.rely(address(vow));
        flop.rely(address(vow));

        cat = new Cat(address(vat));
        cat.file("vow", address(vow));
        cat.file("box", rad(1_000_000 ether));
        cat.file("acme", "chop", WAD);
        cat.file("acme", "dunk", rad(1_000_000 ether));
        vat.rely(address(cat));
        vow.rely(address(cat));

        dai = new DSToken("Dai");
        daiJoin = new DaiJoin(address(vat), address(dai));
        vat.rely(address(daiJoin));
        dai.setOwner(address(daiJoin));

        // the first RWA ilk is Acme Real World Assets Corporation
        vat.init("acme");
        vat.file("Line", 100 * rad(ceiling));
        vat.file("acme", "line", rad(ceiling));

        oracle = new RwaLiquidationOracle(address(vat), address(vow));
        oracle.init(
            "acme",
            wmul(ceiling, 1.1 ether),
            doc,
            2 weeks);
        vat.rely(address(oracle));
        (,address pip,,) = oracle.ilks("acme");

        spot.file("acme", "mat", RAY);
        spot.file("acme", "pip", pip);
        spot.poke("acme");

        gemJoin = new AuthGemJoin(address(vat), "acme", address(rwa));
        vat.rely(address(gemJoin));

        // deploy outward dai conduit
        outConduit = new RwaRoutingConduit(address(gov), address(dai));
        // deploy urn
        urn = new RwaUrn(address(vat), address(gemJoin), address(daiJoin), address(outConduit));
        gemJoin.rely(address(urn));
        // deploy return dai conduit, pointed permanently at the urn
        inConduit = new RwaConduit(address(gov), address(dai), address(urn));

        // deploy user and ultimate dai recipient
        usr = new RwaUser(urn, outConduit, inConduit);
        rec = new RwaUltimateRecipient(dai);

        // fund user with rwa
        rwa.transfer(address(usr), 1 ether);

        // auth user to operate
        urn.hope(address(usr));
        outConduit.hope(address(usr));
        outConduit.kiss(address(rec));

        // usr nominates ultimate recipient
        usr.pick(address(rec));
        usr.approve(rwa, address(urn), uint(-1));
    }

    function test_unpick_and_pick_new_rec() public {
        // unpick current rec
        usr.pick(address(0));

        usr.lock(1 ether);
        usr.draw(400 ether);

        // dai can't move
        assertTrue(! can_push(address(outConduit)));

        // deploy and whitelist new rec
        RwaUltimateRecipient newrec = new RwaUltimateRecipient(dai);
        outConduit.kiss(address(newrec));

        usr.pick(address(newrec));
        outConduit.push();

        assertEq(dai.balanceOf(address(newrec)), 400 ether);
    }

    function test_cant_pick_unkissed_rec() public {
        RwaUltimateRecipient newrec = new RwaUltimateRecipient(dai);
        assertTrue(! usr.can_pick(address(newrec)));
    }

    function test_lock_and_draw() public {
        usr.lock(1 ether);
        usr.draw(400 ether);
        assertEq(dai.balanceOf(address(outConduit)), 400 ether);

        outConduit.push();
        assertEq(dai.balanceOf(address(rec)), 400 ether);
    }

    function test_cant_draw_too_much() public {
        usr.lock(1 ether);
        assertTrue(! usr.can_draw(500 ether));
    }

    function test_cant_draw_as_rando() public {
        usr.lock(1 ether);

        RwaUser rando = new RwaUser(urn, outConduit, inConduit);
        assertTrue(! rando.can_draw(100 ether));
    }

    function test_partial_repay() public {
        usr.lock(1 ether);
        usr.draw(400 ether);

        outConduit.push();

        rec.transfer(address(inConduit), 100 ether);
        assertEq(dai.balanceOf(address(inConduit)), 100 ether);

        inConduit.push();
        usr.wipe(100 ether);

        (, uint art) = vat.urns("acme", address(urn));
        assertEq(art, 300 ether);
        assertEq(dai.balanceOf(address(inConduit)), 0 ether);
    }

    function test_full_repay() public {
        usr.lock(1 ether);
        usr.draw(400 ether);

        outConduit.push();

        rec.transfer(address(inConduit), 400 ether);

        inConduit.push();
        usr.wipe(400 ether);
        usr.free(1 ether);

        (uint ink, uint art) = vat.urns("acme", address(urn));
        assertEq(art, 0);
        assertEq(ink, 0);
        assertEq(rwa.balanceOf(address(usr)), 1 ether);
    }

    function test_oracle_cure() public {
        usr.lock(1 ether);

        // flash the liquidation beacon
        vat.file("acme", "line", rad(0));
        oracle.tell("acme");

        // not able to borrow
        assertTrue(! usr.can_draw(10 ether));

        hevm.warp(now + 1 weeks);

        oracle.cure("acme");
        vat.file("acme", "line", rad(400 ether));
        assertTrue(oracle.good("acme"));

        // able to borrow
        usr.draw(100 ether);
        outConduit.push();
        assertEq(dai.balanceOf(address(rec)), 100 ether);
    }

    function test_oracle_cull() public {
        usr.lock(1 ether);
        // not at full utilisation
        usr.draw(200 ether);

        // flash the liquidation beacon
        vat.file("acme", "line", rad(0));
        oracle.tell("acme");

        // not able to borrow
        assertTrue(! usr.can_draw(10 ether));

        hevm.warp(now + 2 weeks);

        assertEq(vat.gem("acme", address(oracle)), 0);

        oracle.cull("acme", address(urn));

        assertTrue(! oracle.good("acme"));
        assertTrue(! usr.can_draw(10 ether));

        (uint ink, uint art) = vat.urns("acme", address(urn));
        assertEq(ink, 0);
        assertEq(art, 0);

        assertEq(vat.sin(address(vow)), rad(200 ether));

        assertEq(vat.gem("acme", address(oracle)), 1 ether);

        spot.poke("acme");
        (,,uint256 spot ,,) = vat.ilks("acme");
        assertEq(spot, 0);
    }

    function test_oracle_bump() public {
        usr.lock(1 ether);
        usr.draw(400 ether);

        outConduit.push();

        // can't borrow more
        assertTrue(!usr.can_draw(1 ether));

        // increase ceiling by 200 dai
        vat.file("acme", "line", rad(ceiling + 200 ether));
        oracle.bump("acme", wmul(ceiling + 200 ether, 1.1 ether));
        spot.poke("acme");

        usr.draw(200 ether);
        outConduit.push();

        assertEq(dai.balanceOf(address(rec)), 600 ether);
    }
}
