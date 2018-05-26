/**
 * FlightDelay with Oraclized Underwriting and Payout
 *
 * @description	Payout contract
 * @copyright (c) 2017 etherisc GmbH
 * @author Christoph Mussenbrock
 *
 * Hurricane Response with Underwriting and Payout
 * Modified work
 *
 * @copyright (c) 2018 Joel Martínez
 * @author Joel Martínez
 */


pragma solidity ^0.4.11;


import "./HurricaneResponseControlledContract.sol";
import "./HurricaneResponseConstants.sol";
import "./HurricaneResponseDatabaseInterface.sol";
import "./HurricaneResponseAccessControllerInterface.sol";
import "./HurricaneResponseLedgerInterface.sol";
import "./HurricaneResponsePayoutInterface.sol";
import "./HurricaneResponseOraclizeInterface.sol";
import "./convertLib.sol";
import "./../vendors/strings.sol";

contract HurricaneResponsePayout is HurricaneResponseControlledContract, HurricaneResponseConstants, HurricaneResponseOraclizeInterface, ConvertLib {
  using strings for *;

  HurricaneResponseDatabaseInterface HR_DB;
  HurricaneResponseLedgerInterface HR_LG;
  HurricaneResponseAccessControllerInterface HR_AC;

  /*
   * @dev Contract constructor sets its controller
   * @param _controller FD.Controller
   */
  function HurricaneResponsePayout(address _controller) {
    setController(_controller);
  }

  /*
   * Public methods
   */

  /*
   * @dev Set access permissions for methods
   */
  function setContracts() public onlyController {
    HR_AC = HurricaneResponseAccessControllerInterface(getContract("HR.AccessController"));
    HR_DB = HurricaneResponseDatabaseInterface(getContract("HR.Database"));
    HR_LG = HurricaneResponseLedgerInterface(getContract("HR.Ledger"));

    HR_AC.setPermissionById(101, "HR.Underwrite");
    HR_AC.setPermissionByAddress(101, oraclize_cbAddress());
    HR_AC.setPermissionById(102, "HR.Funder");
  }

  /*
   * @dev Fund contract
   */
  function fund() payable {
    require(HR_AC.checkPermission(102, msg.sender));

    // todo: bookkeeping
    // todo: fire funding event
  }

  /*
   * @dev Schedule oraclize call for payout
   * @param _policyId
   * @param _riskId
   * @param _oraclizeTime
   */
  function schedulePayoutOraclizeCall(uint _policyId, bytes32 _riskId, uint _oraclizeTime) public {
    // TODO: decide wether a policy holder could trigger their own payout function
    require(HR_AC.checkPermission(101, msg.sender));

    var (, season) = HR_DB.getRiskParameters(_riskId);
    // Require payout to be in current season
    // TODO: should set policy as expired
    require(season == strings.uintToBytes(getYear(block.timestamp)));

    var (, , , latlng) = HR_DB.getPolicyData(_policyId);

    string memory oraclizeUrl = strConcat(
      ORACLIZE_STATUS_BASE_URL,
      "latlng=",
      b32toString(latlng),
      "&start=2018-05-01", // for testing
      ORACLIZE_STATUS_QUERY
    );

    bytes32 queryId = oraclize_query(_oraclizeTime, "URL", oraclizeUrl, ORACLIZE_GAS);

    HR_DB.createOraclizeCallback(
      queryId,
      _policyId,
      oraclizeState.ForPayout
    );

    LogOraclizeCall(_policyId, queryId, oraclizeUrl);
  }

  /*
   * @dev Oraclize callback. In an emergency case, we can call this directly from FD.Emergency Account.
   * @param _queryId
   * @param _result
   * @param _proof
   */
  function __callback(bytes32 _queryId, string _result, bytes _proof) public onlyOraclizeOr(getContract('HR.Emergency')) {
    var (policyId) = HR_DB.getOraclizeCallback(_queryId);
    LogOraclizeCallback(policyId, _queryId, _result, _proof);

    // check if policy was declined after this callback was scheduled
    var state = HR_DB.getPolicyState(policyId);
    require(uint8(state) != 5);

    bytes32 riskId = HR_DB.getRiskId(policyId);

    if (bytes(_result).length == 0) {
      // empty Result
      // could try again to be redundant
      return;
    }

    // _result looks like: "cat5;100"
    // where first part is event Category
    // and second part is distance from event
    var s = _result.toSlice();
    var delim = ";".toSlice();
    var parts = new string[](s.count(delim) + 1);
    for(uint i = 0; i < parts.length; i++) {
      parts[i] = s.split(delim).toString();
    }

    payOut(policyId, stringToBytes32(parts[0]), parseInt(parts[1]));
  }

  /*
   * Internal methods
   */

  /*
   * @dev Payout
   * @param _policyId internal id
   * @param _category the intensity of the event
   * @param _distance the distance from the latlng to the event
   */
  function payOut(uint _policyId, bytes32 _category, uint _distance) internal {
    // TODO: only setPayoutEvent for the initial trigger
    // this could be a waste of gas
    HR_DB.setHurricaneCategory(_policyId, _category);

    // Distance is more than 30 miles
    if (_distance > 48281) {
      // is too far, therfore not covered
      HR_DB.setState(
        _policyId,
        policyState.Expired,
        now,
        "Too far for payout"
      );
    } else {
      var (customer, weight, premium, ) = HR_DB.getPolicyData(_policyId);

      uint multiplier = 1;
      // 0 - 5 miles
      if (0 < _distance && _distance < 8048) {
        if (_category == "cat3") multiplier = 10;
        if (_category == "cat4") multiplier = 20;
        if (_category == "cat5") multiplier = 30;
      }
      // 5 - 15 miles
      if (8048 < _distance && _distance < 24141) {
        // cat3 pays 50% at this distance
        if (_category == "cat3") multiplier = 5;
        if (_category == "cat4") multiplier = 20;
        if (_category == "cat5") multiplier = 30;
      }
      // 15 - 30 miles
      if (24141 < _distance && _distance < 48280) {
        // cat3 pays 20% at this distance
        if (_category == "cat3") multiplier = 2;
        // cat4 pays 50% at this distance
        if (_category == "cat4") multiplier = 10;
        // cat5 pays 70% at this distance
        if (_category == "cat5") multiplier = 21;
      }

      uint payout = premium * multiplier;
      uint calculatedPayout = payout;

      if (payout > MAX_PAYOUT) {
        payout = MAX_PAYOUT;
      }

      HR_DB.setPayouts(_policyId, calculatedPayout, payout);

      if (!HR_LG.sendFunds(customer, Acc.Payout, payout)) {
        HR_DB.setState(
          _policyId,
          policyState.SendFailed,
          now,
          "Payout, send failed!"
        );

        HR_DB.setPayouts(_policyId, calculatedPayout, 0);
      } else {
        HR_DB.setState(
          _policyId,
          policyState.PaidOut,
          now,
          "Payout successful!"
        );
      }
    }
  }
}
