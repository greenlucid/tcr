/**
 *  @authors: [@unknownunknown1, @mtsalenc]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: [{ link: https://github.com/kleros/tcr/issues/20, maxPayout: 25 ETH }]
 *  @deployments: []
 */

pragma solidity 0.5.17;

import {IArbitrable, IArbitrator} from "@kleros/erc-792/contracts/IArbitrator.sol";
import {IEvidence} from "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import {CappedMath} from "./utils/CappedMath.sol";

/* solium-disable max-len */
/* solium-disable security/no-block-members */
/* solium-disable security/no-send */
// It is the user responsibility to accept ETH.

/**
 *  @title LightGeneralizedTCR
 *  This contract is a curated registry for any types of items. Just like a TCR contract it features the request-challenge protocol and appeal fees crowdfunding.
 */
contract LightGeneralizedTCR is IArbitrable, IEvidence {
    using CappedMath for uint256;

    /* Enums */

    enum Status {
        Absent, // The item is not in the registry.
        Registered, // The item is in the registry.
        RegistrationRequested, // The item has a request to be added to the registry.
        ClearingRequested // The item has a request to be removed from the registry.
    }

    enum Party {
        None, // Party per default when there is no challenger or requester. Also used for unconclusive ruling.
        Requester, // Party that made the request to change a status.
        Challenger // Party that challenges the request to change a status.
    }

    /* Structs */

    struct Item {
        Status status; // The current status of the item.
        Request[] requests; // List of status change requests made for the item in the form requests[requestID].
    }

    // Arrays with 3 elements map with the Party enum for better readability:
    // - 0: is unused, matches `Party.None`.
    // - 1: for `Party.Requester`.
    // - 2: for `Party.Challenger`.
    struct Request {
        bool disputed; // True if a dispute was raised.
        uint256 disputeID; // ID of the dispute, if any.
        uint256 submissionTime; // Time when the request was made. Used to track when the challenge period ends.
        bool resolved; // True if the request was executed and/or any raised disputes were resolved.
        address payable[3] parties; // Address of requester and challenger, if any, in the form parties[party].
        Round[] rounds; // Tracks each round of a dispute in the form rounds[roundID].
        Party ruling; // The final ruling given, if any.
        IArbitrator arbitrator; // The arbitrator trusted to solve disputes for this request.
        bytes arbitratorExtraData; // The extra data for the trusted arbitrator of this request.
        uint256 metaEvidenceID; // The meta evidence to be used in a dispute for this case.
    }

    struct Round {
        uint256[3] amountPaid; // Tracks the sum paid for each Party in this round. Includes arbitration fees, fee stakes and deposits.
        bool[3] hasPaid; // True if the Party has fully paid its fee in this round.
        uint256 feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side in the form contributions[address][party].
    }

    /* Storage */

    bool private initialized;
    IArbitrator public arbitrator; // The arbitrator contract.
    bytes public arbitratorExtraData; // Extra data for the arbitrator contract.

    address public relayContract; // The contract that is used to add or remove items directly to speed up the interchain communication.

    uint256 public constant RULING_OPTIONS = 2; // The amount of non 0 choices the arbitrator can give.

    address public governor; // The address that can make changes to the parameters of the contract.
    uint256 public submissionBaseDeposit; // The base deposit to submit an item.
    uint256 public removalBaseDeposit; // The base deposit to remove an item.
    uint256 public submissionChallengeBaseDeposit; // The base deposit to challenge a submission.
    uint256 public removalChallengeBaseDeposit; // The base deposit to challenge a removal request.
    uint256 public challengePeriodDuration; // The time after which a request becomes executable if not challenged.
    uint256 public metaEvidenceUpdates; // The number of times the meta evidence has been updated. Used to track the latest meta evidence ID.

    // Multipliers are in basis points.
    uint256 public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint256 public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint256 public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where arbitrator refused to arbitrate.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    mapping(bytes32 => Item) public items; // Maps the item ID to its data in the form items[_itemID].
    mapping(address => mapping(uint256 => bytes32))
        public arbitratorDisputeIDToItemID; // Maps a dispute ID to the ID of the item with the disputed request in the form arbitratorDisputeIDToItemID[arbitrator][disputeID].

    /* Modifiers */

    modifier onlyGovernor() {
        require(msg.sender == governor, "The caller must be the governor.");
        _;
    }

    modifier onlyRelay() {
        require(msg.sender == relayContract, "The caller must be the relay.");
        _;
    }

    /* Events */

    /**
     *  @dev Emitted when a party makes a request, raises a dispute or when a request is resolved.
     *  @param _itemID The ID of the affected item.
     */
    event ItemStatusChange(bytes32 indexed _itemID);

    /**
     *  @dev Emitted when someone submits an item for the first time.
     *  @param _itemID The ID of the new item.
     *  @param _data The item data URI.
     */
    event NewItem(bytes32 indexed _itemID, string _data);

    /**
     *  @dev Emitted when someone submits a request.
     *  @param _itemID The ID of the affected item.
     *  @param _evidenceGroupID Unique identifier of the evidence group the evidence belongs to.
     */
    event RequestSubmitted(bytes32 indexed _itemID, uint256 _evidenceGroupID);

    /**
     *  @dev Emitted when a party contributes to an appeal.
     *  @param _itemID The ID of the item.
     *  @param _contributor The address making the contribution.
     *  @param _contribution How much was of the contribution was accepted.
     *  @param _side The party receiving the contribution.
     */
    event Contribution(
        bytes32 indexed _itemID,
        address indexed _contributor,
        uint256 _contribution,
        Party _side
    );

    /** @dev Emitted when the address of the connected TCR is set. The connected TCR is an instance of the Generalized TCR contract where each item is the address of a TCR related to this one.
     *  @param _connectedTCR The address of the connected TCR.
     */
    event ConnectedTCRSet(address indexed _connectedTCR);

    /** @dev Emitted when someone withdraws more than 0 rewards.
     *  @param _beneficiary The address that made contributions to a request.
     *  @param _itemID The ID of the item submission to withdraw.
     *  @param _request The request from which to withdraw.
     *  @param _round The round from which to withdraw.
     */
    event RewardWithdrawn(
        address indexed _beneficiary,
        bytes32 indexed _itemID,
        uint256 _request,
        uint256 _round
    );

    constructor() public {}

    /**
     *  @dev Initialize the arbitrable curated registry.
     *  @param _arbitrator Arbitrator to resolve potential disputes. The arbitrator is trusted to support appeal periods and not reenter.
     *  @param _arbitratorExtraData Extra data for the trusted arbitrator contract.
     *  @param _connectedTCR The address of the TCR that stores related TCR addresses. This parameter can be left empty.
     *  @param _registrationMetaEvidence The URI of the meta evidence object for registration requests.
     *  @param _clearingMetaEvidence The URI of the meta evidence object for clearing requests.
     *  @param _governor The trusted governor of this contract.
     *  @param _baseDeposits The base deposits for requests/challenges as follows:
     *  - The base deposit to submit an item.
     *  - The base deposit to remove an item.
     *  - The base deposit to challenge a submission.
     *  - The base deposit to challenge a removal request.
     *  @param _challengePeriodDuration The time in seconds parties have to challenge a request.
     *  @param _stakeMultipliers Multipliers of the arbitration cost in basis points (see MULTIPLIER_DIVISOR) as follows:
     *  - The multiplier applied to each party's fee stake for a round when there is no winner/loser in the previous round (e.g. when the arbitrator refused to arbitrate).
     *  - The multiplier applied to the winner's fee stake for the subsequent round.
     *  - The multiplier applied to the loser's fee stake for the subsequent round.
     *  @param _relayContract The address of the relay contract to add/remove items directly.
     */
    function initialize(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        address _connectedTCR,
        string memory _registrationMetaEvidence,
        string memory _clearingMetaEvidence,
        address _governor,
        uint256[4] memory _baseDeposits,
        uint256 _challengePeriodDuration,
        uint256[3] memory _stakeMultipliers,
        address _relayContract
    ) public {
        require(!initialized, "Already initialized.");

        emit MetaEvidence(0, _registrationMetaEvidence);
        emit MetaEvidence(1, _clearingMetaEvidence);
        emit ConnectedTCRSet(_connectedTCR);

        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        governor = _governor;
        submissionBaseDeposit = _baseDeposits[0];
        removalBaseDeposit = _baseDeposits[1];
        submissionChallengeBaseDeposit = _baseDeposits[2];
        removalChallengeBaseDeposit = _baseDeposits[3];
        challengePeriodDuration = _challengePeriodDuration;
        sharedStakeMultiplier = _stakeMultipliers[0];
        winnerStakeMultiplier = _stakeMultipliers[1];
        loserStakeMultiplier = _stakeMultipliers[2];
        relayContract = _relayContract;

        initialized = true;
    }

    /* External and Public */

    // ************************ //
    // *       Requests       * //
    // ************************ //

    /** @dev Directly add an item to the list bypassing request-challenge. Can only be used by the relay contract.
     *  @param _item The URI to the item data.
     */
    function addItemDirectly(string calldata _item) external onlyRelay {
        bytes32 itemID = keccak256(abi.encodePacked(_item));
        Item storage item = items[itemID];
        require(
            item.status == Status.Absent,
            "Item must be absent to be added."
        );

        if (item.requests.length == 0) emit NewItem(itemID, _item);

        item.status = Status.Registered;

        emit ItemStatusChange(itemID);
    }

    /** @dev Directly remove an item from the list bypassing request-challenge. Can only be used by the relay contract.
     *  @param _itemID The ID of the item to remove.
     */
    function removeItemDirectly(bytes32 _itemID) external onlyRelay {
        Item storage item = items[_itemID];
        require(
            item.status == Status.Registered,
            "Item must be registered to be removed."
        );

        item.status = Status.Absent;

        emit ItemStatusChange(_itemID);
    }

    /** @dev Submit a request to register an item. Accepts enough ETH to cover the deposit, reimburses the rest.
     *  @param _item The URI to the item data.
     */
    function addItem(string calldata _item) external payable {
        bytes32 itemID = keccak256(abi.encodePacked(_item));
        Item storage item = items[itemID];
        require(
            item.status == Status.Absent,
            "Item must be absent to be added."
        );

        if (item.requests.length == 0) emit NewItem(itemID, _item);

        requestStatusChange(itemID, submissionBaseDeposit);
    }

    /** @dev Submit a request to remove an item from the list. Accepts enough ETH to cover the deposit, reimburses the rest.
     *  @param _itemID The ID of the item to remove.
     *  @param _evidence A link to an evidence using its URI. Ignored if not provided.
     */
    function removeItem(bytes32 _itemID, string calldata _evidence)
        external
        payable
    {
        Item storage item = items[_itemID];
        require(
            item.status == Status.Registered,
            "Item must be registered to be removed."
        );

        // Emit evidence if it was provided.
        if (bytes(_evidence).length > 0) {
            // Using `length` instead of `length - 1` because a new request will be added on requestStatusChange().
            uint256 requestIndex = item.requests.length;
            uint256 evidenceGroupID = uint256(
                keccak256(abi.encodePacked(_itemID, requestIndex))
            );

            emit Evidence(arbitrator, evidenceGroupID, msg.sender, _evidence);
        }

        requestStatusChange(_itemID, removalBaseDeposit);
    }

    /** @dev Challenges the request of the item. Accepts enough ETH to cover the deposit, reimburses the rest.
     *  @param _itemID The ID of the item which request to challenge.
     *  @param _evidence A link to an evidence using its URI. Ignored if not provided.
     */
    function challengeRequest(bytes32 _itemID, string calldata _evidence)
        external
        payable
    {
        Item storage item = items[_itemID];

        require(
            item.status == Status.RegistrationRequested ||
                item.status == Status.ClearingRequested,
            "The item must have a pending request."
        );

        Request storage request = item.requests[item.requests.length - 1];
        require(
            now - request.submissionTime <= challengePeriodDuration,
            "Challenges must occur during the challenge period."
        );
        require(
            !request.disputed,
            "The request should not have already been disputed."
        );

        uint256 arbitrationCost = request.arbitrator.arbitrationCost(
            request.arbitratorExtraData
        );
        uint256 challengerBaseDeposit = item.status ==
            Status.RegistrationRequested
            ? submissionChallengeBaseDeposit
            : removalChallengeBaseDeposit;
        uint256 totalCost = arbitrationCost.addCap(challengerBaseDeposit);
        require(msg.value >= totalCost, "You must fully fund your side.");

        request.parties[uint256(Party.Challenger)] = msg.sender;

        Round storage round = request.rounds[0];
        contribute(
            _itemID,
            round,
            Party.Challenger,
            msg.sender,
            msg.value,
            totalCost
        );
        round.hasPaid[uint256(Party.Challenger)] = true;

        // Raise a dispute.
        request.disputeID = request.arbitrator.createDispute.value(
            arbitrationCost
        )(RULING_OPTIONS, request.arbitratorExtraData);
        arbitratorDisputeIDToItemID[address(request.arbitrator)][
            request.disputeID
        ] = _itemID;
        request.disputed = true;
        request.rounds.length++;
        round.feeRewards = round.feeRewards.subCap(arbitrationCost);

        uint256 evidenceGroupID = uint256(
            keccak256(abi.encodePacked(_itemID, item.requests.length - 1))
        );
        emit Dispute(
            request.arbitrator,
            request.disputeID,
            request.metaEvidenceID,
            evidenceGroupID
        );

        if (bytes(_evidence).length > 0) {
            emit Evidence(
                request.arbitrator,
                evidenceGroupID,
                msg.sender,
                _evidence
            );
        }
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if both sides are fully funded.
     *  @param _itemID The ID of the item which request to fund.
     *  @param _side The recipient of the contribution.
     */
    function fundAppeal(bytes32 _itemID, Party _side) external payable {
        require(
            _side == Party.Requester || _side == Party.Challenger,
            "Invalid side."
        );
        require(
            items[_itemID].status == Status.RegistrationRequested ||
                items[_itemID].status == Status.ClearingRequested,
            "The item must have a pending request."
        );
        Request storage request = items[_itemID].requests[
            items[_itemID].requests.length - 1
        ];
        require(
            request.disputed,
            "A dispute must have been raised to fund an appeal."
        );
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = request
            .arbitrator
            .appealPeriod(request.disputeID);
        require(
            now >= appealPeriodStart && now < appealPeriodEnd,
            "Contributions must be made within the appeal period."
        );

        /* solium-disable indentation */
        uint256 multiplier;
        {
            Party winner = Party(
                request.arbitrator.currentRuling(request.disputeID)
            );
            if (winner == Party.None) {
                multiplier = sharedStakeMultiplier;
            } else if (_side == winner) {
                multiplier = winnerStakeMultiplier;
            } else {
                multiplier = loserStakeMultiplier;
                require(
                    block.timestamp < (appealPeriodStart + appealPeriodEnd) / 2,
                    "The loser must contribute during the first half of the appeal period."
                );
            }
        }
        /* solium-enable indentation */

        Round storage round = request.rounds[request.rounds.length - 1];
        uint256 appealCost = request.arbitrator.appealCost(
            request.disputeID,
            request.arbitratorExtraData
        );
        uint256 totalCost = appealCost.addCap(
            (appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR
        );
        contribute(_itemID, round, _side, msg.sender, msg.value, totalCost);

        if (round.amountPaid[uint256(_side)] >= totalCost) {
            round.hasPaid[uint256(_side)] = true;
        }

        // Raise appeal if both sides are fully funded.
        if (
            round.hasPaid[uint256(Party.Challenger)] &&
            round.hasPaid[uint256(Party.Requester)]
        ) {
            request.arbitrator.appeal.value(appealCost)(
                request.disputeID,
                request.arbitratorExtraData
            );
            request.rounds.length++;
            round.feeRewards = round.feeRewards.subCap(appealCost);
        }
    }

    /** @dev Reimburses contributions if no disputes were raised. If a dispute was raised, sends the fee stake rewards and reimbursements proportionally to the contributions made to the winner of a dispute.
     *  @param _beneficiary The address that made contributions to a request.
     *  @param _itemID The ID of the item submission to withdraw from.
     *  @param _request The request from which to withdraw from.
     *  @param _round The round from which to withdraw from.
     */
    function withdrawFeesAndRewards(
        address payable _beneficiary,
        bytes32 _itemID,
        uint256 _request,
        uint256 _round
    ) public {
        Item storage item = items[_itemID];
        Request storage request = item.requests[_request];
        Round storage round = request.rounds[_round];
        require(request.resolved, "Request must be resolved.");

        uint256 reward;
        if (_round == request.rounds.length - 1) {
            // Reimburse if not enough fees were raised to appeal the ruling.
            reward =
                round.contributions[_beneficiary][uint256(Party.Requester)] +
                round.contributions[_beneficiary][uint256(Party.Challenger)];
        } else if (request.ruling == Party.None) {
            // Reimburse unspent fees proportionally if there is no winner or loser.
            uint256 rewardRequester = round.amountPaid[
                uint256(Party.Requester)
            ] > 0
                ? (round.contributions[_beneficiary][uint256(Party.Requester)] *
                    round.feeRewards) /
                    (round.amountPaid[uint256(Party.Challenger)] +
                        round.amountPaid[uint256(Party.Requester)])
                : 0;
            uint256 rewardChallenger = round.amountPaid[
                uint256(Party.Challenger)
            ] > 0
                ? (round.contributions[_beneficiary][
                    uint256(Party.Challenger)
                ] * round.feeRewards) /
                    (round.amountPaid[uint256(Party.Challenger)] +
                        round.amountPaid[uint256(Party.Requester)])
                : 0;

            reward = rewardRequester + rewardChallenger;
        } else {
            // Reward the winner.
            reward = round.amountPaid[uint256(request.ruling)] > 0
                ? (round.contributions[_beneficiary][uint256(request.ruling)] *
                    round.feeRewards) /
                    round.amountPaid[uint256(request.ruling)]
                : 0;
        }
        round.contributions[_beneficiary][uint256(Party.Requester)] = 0;
        round.contributions[_beneficiary][uint256(Party.Challenger)] = 0;

        if (reward > 0) _beneficiary.send(reward);

        if (reward > 0)
            emit RewardWithdrawn(_beneficiary, _itemID, _request, _round);
    }

    /** @dev Executes an unchallenged request if the challenge period has passed.
     *  @param _itemID The ID of the item to execute.
     */
    function executeRequest(bytes32 _itemID) external {
        Item storage item = items[_itemID];
        Request storage request = item.requests[item.requests.length - 1];
        require(
            now - request.submissionTime > challengePeriodDuration,
            "Time to challenge the request must pass."
        );
        require(!request.disputed, "The request should not be disputed.");

        if (item.status == Status.RegistrationRequested)
            item.status = Status.Registered;
        else if (item.status == Status.ClearingRequested)
            item.status = Status.Absent;
        else revert("There must be a request.");

        request.resolved = true;
        emit ItemStatusChange(_itemID);

        withdrawFeesAndRewards(
            request.parties[uint256(Party.Requester)],
            _itemID,
            item.requests.length - 1,
            0
        ); // Automatically withdraw for the requester.
    }

    /** @dev Give a ruling for a dispute. Can only be called by the arbitrator. TRUSTED.
     *  Accounts for the situation where the winner loses a case due to paying less appeal fees than expected.
     *  @param _disputeID ID of the dispute in the arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) public {
        Party resultRuling = Party(_ruling);
        bytes32 itemID = arbitratorDisputeIDToItemID[msg.sender][_disputeID];
        Item storage item = items[itemID];

        Request storage request = item.requests[item.requests.length - 1];
        Round storage round = request.rounds[request.rounds.length - 1];
        require(_ruling <= RULING_OPTIONS, "Invalid ruling option");
        require(
            address(request.arbitrator) == msg.sender,
            "Only the arbitrator can give a ruling"
        );
        require(!request.resolved, "The request must not be resolved.");

        // The ruling is inverted if the loser paid its fees.
        if (round.hasPaid[uint256(Party.Requester)])
            // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
            resultRuling = Party.Requester;
        else if (round.hasPaid[uint256(Party.Challenger)])
            resultRuling = Party.Challenger;

        emit Ruling(IArbitrator(msg.sender), _disputeID, uint256(resultRuling));
        executeRuling(_disputeID, uint256(resultRuling));
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _itemID The ID of the item which the evidence is related to.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(bytes32 _itemID, string calldata _evidence)
        external
    {
        Item storage item = items[_itemID];
        Request storage request = item.requests[item.requests.length - 1];
        require(!request.resolved, "The dispute must not already be resolved.");

        uint256 evidenceGroupID = uint256(
            keccak256(abi.encodePacked(_itemID, item.requests.length - 1))
        );
        emit Evidence(
            request.arbitrator,
            evidenceGroupID,
            msg.sender,
            _evidence
        );
    }

    // ************************ //
    // *      Governance      * //
    // ************************ //

    /** @dev Change the duration of the challenge period.
     *  @param _challengePeriodDuration The new duration of the challenge period.
     */
    function changeTimeToChallenge(uint256 _challengePeriodDuration)
        external
        onlyGovernor
    {
        challengePeriodDuration = _challengePeriodDuration;
    }

    /** @dev Change the base amount required as a deposit to submit an item.
     *  @param _submissionBaseDeposit The new base amount of wei required to submit an item.
     */
    function changeSubmissionBaseDeposit(uint256 _submissionBaseDeposit)
        external
        onlyGovernor
    {
        submissionBaseDeposit = _submissionBaseDeposit;
    }

    /** @dev Change the base amount required as a deposit to remove an item.
     *  @param _removalBaseDeposit The new base amount of wei required to remove an item.
     */
    function changeRemovalBaseDeposit(uint256 _removalBaseDeposit)
        external
        onlyGovernor
    {
        removalBaseDeposit = _removalBaseDeposit;
    }

    /** @dev Change the base amount required as a deposit to challenge a submission.
     *  @param _submissionChallengeBaseDeposit The new base amount of wei required to challenge a submission.
     */
    function changeSubmissionChallengeBaseDeposit(
        uint256 _submissionChallengeBaseDeposit
    ) external onlyGovernor {
        submissionChallengeBaseDeposit = _submissionChallengeBaseDeposit;
    }

    /** @dev Change the base amount required as a deposit to challenge a removal request.
     *  @param _removalChallengeBaseDeposit The new base amount of wei required to challenge a removal request.
     */
    function changeRemovalChallengeBaseDeposit(
        uint256 _removalChallengeBaseDeposit
    ) external onlyGovernor {
        removalChallengeBaseDeposit = _removalChallengeBaseDeposit;
    }

    /** @dev Change the governor of the curated registry.
     *  @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /** @dev Change the proportion of arbitration fees that must be paid as fee stake by parties when there is no winner or loser.
     *  @param _sharedStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier)
        external
        onlyGovernor
    {
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Change the proportion of arbitration fees that must be paid as fee stake by the winner of the previous round.
     *  @param _winnerStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier)
        external
        onlyGovernor
    {
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Change the proportion of arbitration fees that must be paid as fee stake by the party that lost the previous round.
     *  @param _loserStakeMultiplier Multiplier of arbitration fees that must be paid as fee stake. In basis points.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier)
        external
        onlyGovernor
    {
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Change the arbitrator to be used for disputes that may be raised. The arbitrator is trusted to support appeal periods and not reenter.
     *  @param _arbitrator The new trusted arbitrator to be used in disputes.
     *  @param _arbitratorExtraData The extra data used by the new arbitrator.
     */
    function changeArbitrator(
        IArbitrator _arbitrator,
        bytes calldata _arbitratorExtraData
    ) external onlyGovernor {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /** @dev Change the address of connectedTCR, the Generalized TCR instance that stores addresses of TCRs related to this one.
     *  @param _connectedTCR The address of the connectedTCR contract to use.
     */
    function changeConnectedTCR(address _connectedTCR) external onlyGovernor {
        emit ConnectedTCRSet(_connectedTCR);
    }

    /** @dev Update the meta evidence used for disputes.
     *  @param _registrationMetaEvidence The meta evidence to be used for future registration request disputes.
     *  @param _clearingMetaEvidence The meta evidence to be used for future clearing request disputes.
     */
    function changeMetaEvidence(
        string calldata _registrationMetaEvidence,
        string calldata _clearingMetaEvidence
    ) external onlyGovernor {
        metaEvidenceUpdates++;
        emit MetaEvidence(2 * metaEvidenceUpdates, _registrationMetaEvidence);
        emit MetaEvidence(2 * metaEvidenceUpdates + 1, _clearingMetaEvidence);
    }

    /** @dev Change the address of the relay contract.
     *  @param _relayContract The new address of the relay contract.
     */
    function changeRelayContract(address _relayContract) external onlyGovernor {
        relayContract = _relayContract;
    }

    /* Internal */

    /** @dev Submit a request to change item's status. Accepts enough ETH to cover the deposit, reimburses the rest.
     *  @param _itemID The keccak256 hash of the item data.
     *  @param _baseDeposit The base deposit for the request.
     */
    function requestStatusChange(bytes32 _itemID, uint256 _baseDeposit)
        internal
    {
        Item storage item = items[_itemID];
        Request storage request = item.requests[item.requests.length++];
        uint256 arbitrationCost = arbitrator.arbitrationCost(
            request.arbitratorExtraData
        );
        uint256 totalCost = arbitrationCost.addCap(_baseDeposit);
        require(msg.value >= totalCost, "You must fully fund your side.");

        if (item.status == Status.Absent) {
            item.status = Status.RegistrationRequested;
            request.metaEvidenceID = 2 * metaEvidenceUpdates;
        } else if (item.status == Status.Registered) {
            item.status = Status.ClearingRequested;
            request.metaEvidenceID = 2 * metaEvidenceUpdates + 1;
        }

        request.parties[uint256(Party.Requester)] = msg.sender;
        request.submissionTime = now;
        request.arbitrator = arbitrator;
        request.arbitratorExtraData = arbitratorExtraData;

        Round storage round = request.rounds[request.rounds.length++];
        uint256 evidenceGroupID = uint256(
            keccak256(abi.encodePacked(_itemID, item.requests.length - 1))
        );
        emit RequestSubmitted(_itemID, evidenceGroupID);

        contribute(
            _itemID,
            round,
            Party.Requester,
            msg.sender,
            msg.value,
            totalCost
        );
        round.hasPaid[uint256(Party.Requester)] = true;
    }

    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint256 _available, uint256 _requiredAmount)
        internal
        pure
        returns (uint256 taken, uint256 remainder)
    {
        if (_requiredAmount > _available) return (_available, 0);
        // Take whatever is available, return 0 as leftover ETH.
        else return (_requiredAmount, _available - _requiredAmount);
    }

    /** @dev Make a fee contribution.
     *  @param _itemID The item receiving the contribution.
     *  @param _round The round to contribute.
     *  @param _side The side for which to contribute.
     *  @param _contributor The contributor.
     *  @param _amount The amount contributed.
     *  @param _totalRequired The total amount required for this side.
     *  @return The amount of appeal fees contributed.
     */
    function contribute(
        bytes32 _itemID,
        Round storage _round,
        Party _side,
        address payable _contributor,
        uint256 _amount,
        uint256 _totalRequired
    ) internal returns (uint256) {
        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution; // Amount contributed.
        uint256 remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(
            _amount,
            _totalRequired.subCap(_round.amountPaid[uint256(_side)])
        );
        _round.contributions[_contributor][uint256(_side)] += contribution;
        _round.amountPaid[uint256(_side)] += contribution;
        _round.feeRewards += contribution;

        // Reimburse leftover ETH.
        if (remainingETH > 0) _contributor.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.

        if (contribution > 0)
            emit Contribution(_itemID, msg.sender, contribution, _side);

        return contribution;
    }

    /** @dev Execute the ruling of a dispute.
     *  @param _disputeID ID of the dispute in the arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refused to arbitrate".
     */
    function executeRuling(uint256 _disputeID, uint256 _ruling) internal {
        bytes32 itemID = arbitratorDisputeIDToItemID[msg.sender][_disputeID];
        Item storage item = items[itemID];
        Request storage request = item.requests[item.requests.length - 1];

        Party winner = Party(_ruling);

        if (winner == Party.Requester) {
            // Execute Request.
            if (item.status == Status.RegistrationRequested)
                item.status = Status.Registered;
            else if (item.status == Status.ClearingRequested)
                item.status = Status.Absent;
        } else {
            if (item.status == Status.RegistrationRequested)
                item.status = Status.Absent;
            else if (item.status == Status.ClearingRequested)
                item.status = Status.Registered;
        }

        request.resolved = true;
        request.ruling = Party(_ruling);

        emit ItemStatusChange(itemID);

        // Automatically withdraw first deposits and reimbursements (first round only).
        if (winner == Party.None) {
            withdrawFeesAndRewards(
                request.parties[uint256(Party.Requester)],
                itemID,
                item.requests.length - 1,
                0
            );
            withdrawFeesAndRewards(
                request.parties[uint256(Party.Challenger)],
                itemID,
                item.requests.length - 1,
                0
            );
        } else {
            withdrawFeesAndRewards(
                request.parties[uint256(winner)],
                itemID,
                item.requests.length - 1,
                0
            );
        }
    }

    // ************************ //
    // *       Getters        * //
    // ************************ //

    /** @dev Gets the contributions made by a party for a given round of a request.
     *  @param _itemID The ID of the item.
     *  @param _request The request to query.
     *  @param _round The round to query.
     *  @param _contributor The address of the contributor.
     *  @return contributions The contributions.
     */
    function getContributions(
        bytes32 _itemID,
        uint256 _request,
        uint256 _round,
        address _contributor
    ) external view returns (uint256[3] memory contributions) {
        Item storage item = items[_itemID];
        Request storage request = item.requests[_request];
        Round storage round = request.rounds[_round];
        contributions = round.contributions[_contributor];
    }

    /** @dev Returns item's information. Includes length of requests array.
     *  @param _itemID The ID of the queried item.
     *  @return status The current status of the item.
     *  @return numberOfRequests Length of list of status change requests made for the item.
     */
    function getItemInfo(bytes32 _itemID)
        external
        view
        returns (Status status, uint256 numberOfRequests)
    {
        Item storage item = items[_itemID];
        return (item.status, item.requests.length);
    }

    /** @dev Gets information on a request made for the item.
     *  @param _itemID The ID of the queried item.
     *  @param _request The request to be queried.
     *  @return disputed True if a dispute was raised.
     *  @return disputeID ID of the dispute, if any..
     *  @return submissionTime Time when the request was made.
     *  @return resolved True if the request was executed and/or any raised disputes were resolved.
     *  @return parties Address of requester and challenger, if any.
     *  @return numberOfRounds Number of rounds of dispute.
     *  @return ruling The final ruling given, if any.
     *  @return arbitrator The arbitrator trusted to solve disputes for this request.
     *  @return arbitratorExtraData The extra data for the trusted arbitrator of this request.
     *  @return metaEvidenceID The meta evidence to be used in a dispute for this case.
     */
    function getRequestInfo(bytes32 _itemID, uint256 _request)
        external
        view
        returns (
            bool disputed,
            uint256 disputeID,
            uint256 submissionTime,
            bool resolved,
            address payable[3] memory parties,
            uint256 numberOfRounds,
            Party ruling,
            IArbitrator requestArbitrator,
            bytes memory requestArbitratorExtraData,
            uint256 metaEvidenceID
        )
    {
        Request storage request = items[_itemID].requests[_request];
        return (
            request.disputed,
            request.disputeID,
            request.submissionTime,
            request.resolved,
            request.parties,
            request.rounds.length,
            request.ruling,
            request.arbitrator,
            request.arbitratorExtraData,
            request.metaEvidenceID
        );
    }

    /** @dev Gets the information of a round of a request.
     *  @param _itemID The ID of the queried item.
     *  @param _request The request to be queried.
     *  @param _round The round to be queried.
     *  @return appealed Whether appealed or not.
     *  @return amountPaid Tracks the sum paid for each Party in this round.
     *  @return hasPaid True if the Party has fully paid its fee in this round.
     *  @return feeRewards Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
     */
    function getRoundInfo(
        bytes32 _itemID,
        uint256 _request,
        uint256 _round
    )
        external
        view
        returns (
            bool appealed,
            uint256[3] memory amountPaid,
            bool[3] memory hasPaid,
            uint256 feeRewards
        )
    {
        Item storage item = items[_itemID];
        Request storage request = item.requests[_request];
        Round storage round = request.rounds[_round];
        return (
            (_round + 1) < request.rounds.length - 1,
            round.amountPaid,
            round.hasPaid,
            round.feeRewards
        );
    }
}