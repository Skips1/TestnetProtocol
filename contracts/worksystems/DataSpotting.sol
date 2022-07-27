// SPDX-License-Identifier: GPL-3.0
// File: attrstore/AttributeStore.sol

pragma solidity 0.8.0;

library AttributeStore {
    struct SpottedData {
        mapping(bytes32 => uint256) store;
    }

    function getAttribute(SpottedData storage self, bytes32  _UUID, string memory _attrName)
    public view returns (uint256) {
        
        bytes32 key = keccak256(abi.encodePacked(_UUID, _attrName));
        return self.store[key];
    }

    function setAttribute(SpottedData storage self, bytes32 _UUID, string memory _attrName, uint256 _attrVal)
    public {
        bytes32 key = keccak256(abi.encodePacked(_UUID, _attrName));
        self.store[key] = _attrVal;
    }
}

// File: dll/DLL.sol

library DLL {

  uint256 constant NULL_NODE_ID = 0;

  struct Node {
    uint256 next;
    uint256 prev;
  }

  struct SpottedData {
    mapping(uint256 => Node) dll;
  }

  function isEmpty(SpottedData storage self) public view returns (bool) {
    return getStart(self) == NULL_NODE_ID;
  }

  function contains(SpottedData storage self, uint256 _curr) public view returns (bool) {
    if (isEmpty(self) || _curr == NULL_NODE_ID) {
      return false;
    } 

    bool isSingleNode = (getStart(self) == _curr) && (getEnd(self) == _curr);
    bool isNullNode = (getNext(self, _curr) == NULL_NODE_ID) && (getPrev(self, _curr) == NULL_NODE_ID);
    return isSingleNode || !isNullNode;
  }

  function getNext(SpottedData storage self, uint256 _curr) public view returns (uint256) {
    return self.dll[_curr].next;
  }

  function getPrev(SpottedData storage self, uint256 _curr) public view returns (uint256) {
    return self.dll[_curr].prev;
  }

  function getStart(SpottedData storage self) public view returns (uint256) {
    return getNext(self, NULL_NODE_ID);
  }

  function getEnd(SpottedData storage self) public view returns (uint256) {
    return getPrev(self, NULL_NODE_ID);
  }

  /**
  @dev Inserts a new node between _prev and _next. When inserting a node already existing in 
  the list it will be automatically removed from the old position.
  @param _prev the node which _new will be inserted after
  @param _curr the id of the new node being inserted
  @param _next the node which _new will be inserted before
  */
  function insert(SpottedData storage self, uint256 _prev, uint256 _curr, uint256 _next) public {
    require(_curr != NULL_NODE_ID,"error: could not insert, 1");

    remove(self, _curr);

    require(_prev == NULL_NODE_ID || contains(self, _prev),"error: could not insert, 2");
    require(_next == NULL_NODE_ID || contains(self, _next),"error: could not insert, 3");

    require(getNext(self, _prev) == _next,"error: could not insert, 4");
    require(getPrev(self, _next) == _prev,"error: could not insert, 5");

    self.dll[_curr].prev = _prev;
    self.dll[_curr].next = _next;

    self.dll[_prev].next = _curr;
    self.dll[_next].prev = _curr;
  }

  function remove(SpottedData storage self, uint256 _curr) public {
    if (!contains(self, _curr)) {
      return;
    }

    uint256 next = getNext(self, _curr);
    uint256 prev = getPrev(self, _curr);

    self.dll[next].prev = prev;
    self.dll[prev].next = next;

    delete self.dll[_curr];
  }
}



interface IStakeManager {
    function ProxyStakeAllocate(uint256 _StakeAllocation, address _stakeholder) external returns(bool);
    function ProxyStakeDeallocate(uint256 _StakeToDeallocate, address _stakeholder) external returns(bool);
}

interface IRepManager {
    function mintReputationForWork(uint256 _amount, address _beneficiary, bytes32) external returns (bool);    
    function burnReputationForWork(uint256 _amount, address _beneficiary, bytes32) external returns (bool);
}

interface IRewardManager {
    function ProxyAddReward(uint256 _RewardsAllocation, address _user) external returns(bool);
}

interface IAddressManager {
    function isSenderMasterOf(address _address) external returns (bool);
    function isSenderSubOf(address _master) external returns (bool);
    function isSubAddress(address _master, address _address) external returns (bool);
    function addAddress(address _address) external;
    function removeAddress(address _address) external;        
}

interface IFormattingSystem {
    function Ping(uint256 CheckedBatchId) external;    
}


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./RandomAllocator.sol";

/**
@title WorkSystem Spot v0.2
@author Mathias Dail
*/
contract DataSpotting is Ownable, RandomAllocator {

    // ================================================================================================
    // Success ratios of the WorkSystem pipeline are defined depending on task subjectivity & complexity.
    //     Desired overall success ratio is defined as the following: Data Output flux >= 0.80 Data Input Flux. This translates 
    //     in the following:
    //         - Spotting: 0. 90%
    //         - Spot-Checking: 0.99%
    //         - Formatting: 0.95%
    //         - Format-Checking: 0.99%
    //         - Archiving: 0.99%
    //         - Archive-Checking: 0.99%            
    // ================================================================================================
    //     This leaves room for 1% spread out on "frozen stakes" (stakes that are attributed to work that is never processed
    //     by the rest of the pipeline) & flagged content. This is allocated as follows: 
    //         - Frozen Spot Stakes: 0.3%
    //         - Frozen Spot-Checking Stakes: 0.2%
    //         - Frozen Formatting Stakes: 0.2%
    //         - Frozen Format-Checking Stakes: 0.1%
    //         - Frozen Archiving Stakes: 0.1%
    //         - Flagged Content: 0.1%
    // ================================================================================================

    
    // ============
    // EVENTS:
    // ============

    event _SpotSubmitted(uint256 indexed DataID, string file_hash, string URL_domain, address indexed sender);
    event _SpotCheckCommitted(uint256 indexed DataID, uint256 numTokens, address indexed voter);
    event _SpotCheckRevealed(uint256 indexed DataID, uint256 numTokens, uint256 votesFor, uint256 votesAgainst, uint256 indexed choice, address indexed voter);
    event _SpotAccepted(string hash, address indexed creator);    
    event _WorkAllocated(uint256 indexed batchID, address worker);
    event _WorkerRegistered(address indexed worker, uint256 timestamp);
    event _WorkerUnregistered(address indexed worker, uint256 timestamp);

    event _NewEpoch(uint256 indexed epochNumber);
    event _VotingRightsGranted(uint256 numTokens, address indexed voter);
    event _VotingRightsWithdrawn(uint256 numTokens, address indexed voter);
    event _TokensRescued(uint256 indexed DataID, address indexed voter);

    // ============
    // SpottedData STRUCTURES:
    // ============

    using AttributeStore for AttributeStore.SpottedData;
    using DLL for DLL.SpottedData;
    using SafeMath for uint256;
    
    enum DataStatus{
        TBD,
        APPROVED,
        REJECTED,
        FLAGGED
    }


    struct WorkerState {
        address worker_address;                 // worker address
        address master_address;                 // main/master worker Address
        uint256 allocated_work_batch;
        bool has_completed_work;
        uint256 last_worked_round;              
        uint256 last_interaction_date;  
        string extra;                          // extra_data
        bool registered;
        bool unregistration_request;
        uint256 registration_date;       
        uint256 majority_counter;              
        uint256 minority_counter;  
    }
    
    struct BatchMetadata {
        uint256 start_idx;
        uint256 counter;
        uint256 uncommited_workers;
        uint256 unrevealed_workers;
        bool complete;
        bool checked;
        bool allocated_to_work;
        uint256 commitEndDate;                      // expiration date of commit period for poll
        uint256 revealEndDate;                      // expiration date of reveal period for poll
        uint256 votesFor;		                    // tally of spot-check-votes supporting proposal
        uint256 votesAgainst;                       // tally of spot-check-votes countering proposal
        string batchIPFSfile;                       // to be updated during SpotChecking
        uint256 item_count;
        DataStatus status;                          // state of the vote
    }

    struct SpottedData {
        string ipfs_hash;                       // expiration date of commit period for SpottedData
        address author;                         // author of the proposal
        uint256 timestamp;                      // expiration date of commit period for SpottedData
        uint256 item_count;
        string URL_domain;                      // URL domain
        string extra;                           // extra_data
        DataStatus status;                      // state of the vote
    }

    // ============
    // STATE VARIABLES:
    // ============

    uint256 constant INITIAL_Data_NONCE = 0;
    uint256 constant INITIAL_Checks_NONCE = 0;
    uint256 constant MAX_TOTAL_WORKERS = 1000;

    uint256 public DATA_BATCH_SIZE = 1;
    uint256 public CONSENSUS_WORKER_SIZE  = 2;
    uint256 public MIN_CONSENSUS_WORKER_COUNT  = 1;    

    uint256 public MIN_STAKE;
    // all durations are in seconds
    uint256 public COMMIT_ROUND_DURATION;
    uint256 public REVEAL_ROUND_DURATION;        
    uint256 public INTER_ALLOCATION_DURATION;
    uint256 public LastAllocationTime = 0;

    uint256 public MIN_REWARD_Data = 1 * (10 ** 18);
    uint256 public MIN_REP_Data  = 25 * (10 ** 18);
    uint256 public VOTE_QUORUM  = 60;    


    mapping(address => mapping(uint256 => bool)) public UserChecksCommits;     // indicates whether an address committed a spot-check-vote for this poll
    mapping(address => mapping(uint256 => bool)) public UserChecksReveals;     // indicates whether an address revealed a spot-check-vote for this poll
    mapping(uint256 => mapping(address => uint256)) public UserVotes;     // maps DataID -> user addresses ->  vote option
    mapping(uint256 => mapping(address => string)) public UserNewFiles;     // maps DataID -> user addresses -> ipfs string -> counter
    mapping(uint256 => mapping(address => uint256)) public UserBatchCounts;     // maps DataID -> user addresses -> ipfs string -> counter
    mapping(uint256 => mapping(address => string)) public UserBatchFrom;     // maps DataID -> user addresses -> ipfs string -> counter


    mapping(address => DLL.SpottedData) dllMap;
    AttributeStore.SpottedData store;
    
    uint256 public CurrentWorkEpoch = 0;
    uint256 public DataNonce = 0;
    

    mapping(address => WorkerState) public WorkersState;
    mapping(uint256 => SpottedData) public SpotsMapping; // maps DataID to SpottedData struct
    mapping(address => uint256[]) public userSubmissions; // maps user's Addresses to DataIDs they submitted
    mapping(address => uint256) public SpotStakedTokenBalance; // maps user's address to voteToken balance


    mapping(address => address[]) public MasterWorkers;
    address[] public availableWorkers;
    address[] public busyWorkers;   
    address[] public toUnregisterWorkers;   
    mapping(uint256 => address[]) public WorkersPerBatch;

    address public sFuel = 0x14F52f3FC010ab6cA81568D4A6794D5eAB3c6155; //whispering turais testnet, sFuel top up contract
    // owner of sFuelDistributor / Faucet needs to whitelist this contract


    uint256 public LastBatchCounter = 1;
    uint256 public BatchCheckingCursor = 1;
    uint256 public AllocatedBatchCursor = 1;
    mapping(uint256 => BatchMetadata) public DataBatch; // refers to SpottedData indices
    
    uint256 public AllTxsCounter = 0;
    uint256 public AcceptedBatchsCounter = 0;
    uint256 public RejectedBatchsCounter = 0;
    uint256 public NotCommitedCounter = 0;
    uint256 public NotRevealedCounter = 0;

    IERC20 public token;
    IStakeManager public StakeManager;
    IRepManager public RepManager;
    IRewardManager public RewardManager;
    IAddressManager public AddressManager;
    IFormattingSystem public FormattingSystem;



    /**
    @dev Initializer. Can only be called once.
    */
    constructor(address EXDT_token)  {        
        token = IERC20(EXDT_token);

        DataNonce = INITIAL_Data_NONCE;
        
        MIN_STAKE = 25 * (10 ** 18); 
        COMMIT_ROUND_DURATION = 180;
        REVEAL_ROUND_DURATION = 180;
        INTER_ALLOCATION_DURATION = 10;
    }
    

    function updateStakeManager(address addr)
    public
    onlyOwner
    {
        StakeManager = IStakeManager(addr);
    }
    
    function updateRepManager(address addr)
    public
    onlyOwner
    {
        RepManager  = IRepManager(addr);
    }
    
    function updateRewardManager(address addr)
    public
    onlyOwner
    {
        RewardManager  = IRewardManager(addr);
    }

    function updateDataBachSize(uint256 size)
    public
    onlyOwner
    {
        DATA_BATCH_SIZE  = size;
    }
    
    function updateAddressManager(address addr)
    public
    onlyOwner
    {
        AddressManager  = IAddressManager(addr);
    }

    function updateFormattingSystem(address addr)
    public
    onlyOwner
    {
        FormattingSystem  = IFormattingSystem(addr);
    }
    
    
    function updateCommitRoundDuration(uint256 COMMIT_ROUND_DURATION_)
    public
    onlyOwner
    {
        COMMIT_ROUND_DURATION  = COMMIT_ROUND_DURATION_;
    }
    
    function updateInterAllocationDuration(uint256 INTER_ALLOCATION_DURATION_)
    public
    onlyOwner
    {
        INTER_ALLOCATION_DURATION  = INTER_ALLOCATION_DURATION_;
    }

    function updateRevealRoundDuration(uint256 REVEAL_ROUND_DURATION_)
    public
    onlyOwner
    {
        REVEAL_ROUND_DURATION  = REVEAL_ROUND_DURATION_;
    }

    function updateConsensusSize(uint256 CONSENSUS_WORKER_SIZE_)
    public
    onlyOwner
    {
        CONSENSUS_WORKER_SIZE  = CONSENSUS_WORKER_SIZE_;
    }

    function updateMinConsensusSize(uint256 CONSENSUS_WORKER_SIZE_)
    public
    onlyOwner
    {
        require(CONSENSUS_WORKER_SIZE_>=1);
        MIN_CONSENSUS_WORKER_COUNT  = CONSENSUS_WORKER_SIZE_;
    }

    function updateVoteQuoum(uint256 VOTE_QUORUM_)
    public
    onlyOwner
    {
        require(VOTE_QUORUM_>=0 && VOTE_QUORUM_<=100);
        VOTE_QUORUM  = VOTE_QUORUM_;
    }

    // --------------- SFUEL MANAGEMENT SYSTEM ---------------
    // ---------------


    function updatesFuelFaucet(address _sFuel)
    public
    onlyOwner
    {
        sFuel  = _sFuel;
    }

    function _retrieveSFuel() internal {
        require(sFuel != address(0), "0 Address Not Valid");
		(bool success1, /* bytes memory data1 */) = sFuel.call(abi.encodeWithSignature("retrieveSFuel(address)", payable(msg.sender)));
        (bool success2, /* bytes memory data2 */) = sFuel.call(abi.encodeWithSignature("retrieveSFuel(address payable)", payable(msg.sender)));
        require(( success1 || success2 ), "receiver rejected _retrieveSFuel call");

    }

    modifier topUpSFuel {
            _retrieveSFuel();
            _;
    }
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    //                          WORKER REGISTRATION & LOBBY MANAGEMENT
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    

    function isInAvailableWorkers(address _worker) internal view returns(bool){
        bool found = false;
        for(uint256 i = 0; i< availableWorkers.length; i++){
            if(availableWorkers[i] == _worker){
                found = true;
                break;
            }
        }
        return found;
    }

    function isInBusyWorkers(address _worker) internal view returns(bool){
        bool found = false;
        for(uint256 i = 0; i< busyWorkers.length; i++){
            if(busyWorkers[i] == _worker){
                found = true;
                break;
            }
        }
        return found;
    }

    
    function PopFromAvailableWorkers(address _worker) internal{
        uint256 index = 0;
        bool found = false;
        for(uint256 i = 0; i< availableWorkers.length; i++){
            if(availableWorkers[i] == _worker){
                found = true;
                index = i;
                break;
            }
        }
        // require(found, "not found when PopFromAvailableWorkers");
        if(found){
            availableWorkers[index] = availableWorkers[availableWorkers.length - 1];
            availableWorkers.pop();
        }
    }

    function PopFromBusyWorkers(address _worker) internal{
        uint256 index = 0;
        bool found = false;
        for(uint256 i = 0; i< busyWorkers.length; i++){
            if(busyWorkers[i] == _worker){
                found = true;
                index = i;
                break;
            }
        }
        // require(found, "not found when PopFromBusyWorkers");
        if(found){
            busyWorkers[index] = busyWorkers[busyWorkers.length - 1];
            busyWorkers.pop();
        }
    }

    function isWorkerAllocatedToBatch(uint256 _DataBatchId, address _worker) public view returns(bool){
        bool found = false;
        address[] memory allocated_workers_ = WorkersPerBatch[_DataBatchId];
        for(uint256 i = 0; i< allocated_workers_.length; i++){
            if(allocated_workers_[i] == _worker){
                found = true;
                break;
            }
        }
        return found;
    }


    /////////////////////////////////////////////////////////////////////
    /* Register worker (online) */
    function RegisterWorker() public topUpSFuel {
        WorkerState storage worker_state = WorkersState[msg.sender];
        require((availableWorkers.length+busyWorkers.length) < MAX_TOTAL_WORKERS, "Maximum registered workers already");
        require(worker_state.registered == false, "Worker is already registered");
        uint256 now_ = block.timestamp;
        
        //_numTokens The number of tokens to be committed towards the target SpottedData
        uint256 _numTokens = MIN_STAKE;
        
        // if msg.sender doesn't have enough voting rights,
        // request for enough voting rights
        if (SpotStakedTokenBalance[msg.sender] < _numTokens) {
            uint256 remainder = _numTokens.sub(SpotStakedTokenBalance[msg.sender]);
            requestVotingRights(remainder);
        }

        // make sure msg.sender has enough voting rights
        require(SpotStakedTokenBalance[msg.sender] >= _numTokens, "Worker has not enough (_numTokens) in his SpotStakedTokenBalance ");
        //////////////////////////////////
        if(!isInAvailableWorkers(msg.sender)){
            availableWorkers.push(msg.sender);
        }
        // busyWorkers;
        worker_state.worker_address = msg.sender;
        worker_state.master_address = msg.sender;
        worker_state.last_interaction_date = now_;
        if(worker_state.registered == false){
            worker_state.registered = true;
            worker_state.registration_date = block.timestamp;
        }

        AllTxsCounter += 1;
        emit _WorkerRegistered(msg.sender, now_);
    }

    /////////////////////////////////////////////////////////////////////
    /* Unregister worker (offline) */
    function UnregisterWorker() public topUpSFuel {
        WorkerState storage worker_state = WorkersState[msg.sender];
        require(worker_state.registered == true, "Worker is not registered so can't unregister");
        if( worker_state.allocated_work_batch != 0 && worker_state.unregistration_request == false ){
            worker_state.unregistration_request = true;
            toUnregisterWorkers.push(msg.sender);
        }
        else{                
            require(worker_state.allocated_work_batch == 0, "Worker currently has work allocated, can't be unregistered");
            uint256 now_ = block.timestamp;
            //////////////////////////////////
            PopFromAvailableWorkers(msg.sender);
            PopFromBusyWorkers(msg.sender);
            worker_state.worker_address = msg.sender;
            worker_state.master_address = msg.sender;
            worker_state.last_interaction_date = now_;
            worker_state.registered = false;
            emit _WorkerUnregistered(msg.sender, now_);
        }

        AllTxsCounter += 1;
    }


    //////////////////////////////// DELETION FUNCTIONS
    function deleteData(uint256 _DataId)
    public
    onlyOwner
    {
        delete SpotsMapping[_DataId];
    }

    function deleteDataBatch(uint256 _BatchId)
    public
    onlyOwner
    {
        if(DataExists(_BatchId)){
            delete DataBatch[_BatchId];
        }
    }

    ////////////////////////////////
    function TriggerNextEpoch()  public topUpSFuel {
        bool progress = false;
        // Log off waiting users first
        if(toUnregisterWorkers.length > 0){
            processLogoffRequests();
        }
        // IF CURRENT BATCH IS ALLOCATED TO WORKERS AND VOTE HAS ENDED, THEN CHECK IT & MOVE ON!
        if( DataBatch[BatchCheckingCursor].allocated_to_work == true 
            && ( DataEnded(BatchCheckingCursor) || ( DataBatch[BatchCheckingCursor].unrevealed_workers == 0 ) )){
            ValidateDataBatch(BatchCheckingCursor);            
            BatchCheckingCursor = BatchCheckingCursor.add(1);        
            progress = true;
        }
        // IF CURRENT BATCH IS COMPLETE AND NOT ALLOCATED TO WORKERS TO BE CHECKED, THEN ALLOCATE!
        if( DataBatch[AllocatedBatchCursor].allocated_to_work != true  
            && availableWorkers.length > 0 
            && DataBatch[AllocatedBatchCursor].complete
            && ((block.timestamp - LastAllocationTime) >= INTER_ALLOCATION_DURATION) ){ //nothing to allocate, waiting for this to end
            AllocateWork(); 
            progress = true;
        }
        // then move on with the next epoch, if not enough workers, we just stall until we get a new batch.
        if(progress){
            // ---------------- GLOBAL STATE UPDATE ----------------
            CurrentWorkEpoch = CurrentWorkEpoch.add(1);   
        }
        emit _NewEpoch(CurrentWorkEpoch);
    }

    /////////////
    function processLogoffRequests() internal{
        for (uint256 i = 0; i < toUnregisterWorkers.length; i++) {
            address worker_addr_ = toUnregisterWorkers[i];
            WorkerState storage worker_state = WorkersState[worker_addr_];
            worker_state.registered = false;
            worker_state.unregistration_request = false;
            PopFromAvailableWorkers(worker_addr_);
            PopFromBusyWorkers(worker_addr_);
        }
        delete toUnregisterWorkers;
    }


    /////////////
    function AreStringsEqual(string memory _a, string memory _b) public pure returns(bool){
        if (keccak256(abi.encodePacked(_a)) == keccak256(abi.encodePacked(_b))) {
            return true;
        }
        else{
            return false;
        }
    }
    event BytesFailure(bytes bytesFailure);

    /**
    @notice Trigger the validation of a SpottedData hash; if the SpottedData has ended. If the requirements are APPROVED, 
    the CheckedData will be added to the APPROVED list of SpotCheckings
    @param _DataBatchId Integer identifier associated with target SpottedData
    */
    function ValidateDataBatch(uint256 _DataBatchId) internal {
        require( DataEnded(_DataBatchId) || ( DataBatch[_DataBatchId].unrevealed_workers == 0 ), "_DataBatchId has not ended, or not every voters have voted"); // votes needs to be closed
        require( DataBatch[_DataBatchId].checked == false, "_DataBatchId is already validated"); // votes needs to be closed
        address[] memory allocated_workers_ = WorkersPerBatch[_DataBatchId];
        string[] memory proposedNewFiles = new string[](allocated_workers_.length);
        uint256[] memory proposedBatchCounts = new uint256[](allocated_workers_.length);
        
        // -------------------------------------------------------------
        // GATHER USER SUBMISSIONS AND VOTE INPUTS BEFORE ASSESSMENT
        for (uint256 i = 0; i < allocated_workers_.length; i++) {
            address worker_addr_ = allocated_workers_[i];
            string memory worker_proposed_new_file_ = UserNewFiles[_DataBatchId][worker_addr_];
            uint256 worker_proposed_new_count_ = UserBatchCounts[_DataBatchId][worker_addr_];
            proposedNewFiles[i] = worker_proposed_new_file_;
            proposedBatchCounts[i] = worker_proposed_new_count_;
        }

        // -------------------------------------------------------------
        // MAJORITY QUORUM COMPUTATION
        uint256 majority_min_count = Math.max(allocated_workers_.length * VOTE_QUORUM / 100, 1);

        // GET THE MAJORITY NEW HASH IPFS FILE
        string memory majorityNewFile = proposedNewFiles[0]; //take first file by default, just in case
        for(uint256 k = 0; k < proposedNewFiles.length; k++){
            // count if this given New File is submitted by a majority
            uint256 counter = 0;
            for(uint256 l = 0; l < proposedNewFiles.length; l++){            
                if(AreStringsEqual(proposedNewFiles[k], proposedNewFiles[l])){
                    counter += 1;
                    if(counter >= majority_min_count){
                        break;
                    }
                }
            }
            if(counter >= majority_min_count){
                majorityNewFile = proposedNewFiles[k];
                break;
            }
        }

        // GET THE MAJORITY BATCH COUNT
        uint256  majorityBatchCount = proposedBatchCounts[0]; //take first file by default, just in case
        for(uint256 k = 0; k < proposedBatchCounts.length; k++){
            // count if this given New File is submitted by a majority
            uint256 counter = 0;
            for(uint256 l = 0; l < proposedBatchCounts.length; l++){                    
                if(proposedBatchCounts[k] == proposedBatchCounts[l]){
                    counter += 1;
                    if(counter >= majority_min_count){
                        break;
                    }
                }
            }
            if(counter >= majority_min_count){
                majorityBatchCount = proposedBatchCounts[k];
                break;
            }
        }

        // -------------------------------------------------------------
        // ASSESS VOTE RESULT AND REWARD USERS ACCORDINGLY
        bool isCheckPassed = isPassed(_DataBatchId);

        for (uint256 i = 0; i < allocated_workers_.length; i++) {
            address worker_addr_ = allocated_workers_[i];
            uint256 worker_vote_ = UserVotes[_DataBatchId][worker_addr_];
            bool has_worker_voted_ = UserChecksReveals[worker_addr_][_DataBatchId];  

            // Worker state update
            //// because was busy a task, remove the worker from the busy pool
            PopFromBusyWorkers(worker_addr_);
            WorkerState storage worker_state = WorkersState[worker_addr_];

            if(has_worker_voted_){
                // mark that worker has completed job, no matter the reward
                WorkersState[worker_addr_].has_completed_work = true;
                // then assess if worker is in the majority to reward him
                if( (isCheckPassed == true && worker_vote_ == 1)
                    || (isCheckPassed == false && worker_vote_ != 1) ){
                    // vote 1 == OK, else = NOT OK, rejected     
                    // reward worker if he voted like the majority             
                    require(RepManager.mintReputationForWork(MIN_REP_Data, worker_addr_, ""), "could not reward REP in TriggerCheckSpot, 1.a");
                    require(RewardManager.ProxyAddReward(MIN_REWARD_Data, worker_addr_), "could not reward token in TriggerCheckSpot, 1.b");
                }
                // mark worker back available, removed from the busy list, if the worker has not requested unregistration
                if(worker_state.registered){ // only if the worker is still registered, of course.
                    if(!isInAvailableWorkers(worker_addr_) && (worker_state.unregistration_request == false)){
                        availableWorkers.push(worker_addr_);
                    }
                }
            }
            // if worker has not voted, he is disconnected "by force" OR if asked to be unregistered
            // this worker will have to register again
            else if( worker_state.unregistration_request || has_worker_voted_ == false ){                      
                if(worker_state.registered){ // only if the worker is still registered
                    worker_state.registered = false;
                    PopFromAvailableWorkers(worker_addr_);
                    PopFromBusyWorkers(worker_addr_);
                }
            }
            // General Worker State Update
            worker_state.allocated_work_batch == 0;
        }
        // -------------------------------------------------------------
        // BATCH STATE UPDATE: mark it checked, final.
        DataBatch[_DataBatchId].checked = true;
        DataBatch[_DataBatchId].batchIPFSfile = majorityNewFile;
        DataBatch[_DataBatchId].item_count = majorityBatchCount;
        // -------------------------------------------------------------
        // IF THE DATA BLOCK IS ACCEPTED
        if(isCheckPassed){           
            // Reward Spotters involved in the Batch
            uint256 start_batch_idx = DataBatch[_DataBatchId].start_idx;
            uint256 end_batch_idx = DataBatch[_DataBatchId].start_idx + DataBatch[_DataBatchId].counter;
            
            for(uint256 l = start_batch_idx; l < end_batch_idx; l++){
                address spot_author_ = SpotsMapping[l].author;
                require(RepManager.mintReputationForWork(MIN_REP_Data, spot_author_, ""), "could not reward REP in TriggerCheckSpot, 2.a");
                require(RewardManager.ProxyAddReward(MIN_REWARD_Data, spot_author_), "could not reward token in TriggerCheckSpot, 2.b");
            }

            // UPDATE BATCH STATE
            DataBatch[_DataBatchId].status = DataStatus.APPROVED;
            AcceptedBatchsCounter += 1;

            // SEND THIS BATCH TO THIS FORMATTING SYSTEM
            try FormattingSystem.Ping(_DataBatchId){
                AllTxsCounter += 1;
            } catch(bytes memory err) {
                emit BytesFailure(err);
            }
        }
        // -------------------------------------------------------------
        // IF THE DATA BLOCK IS REJECTED
        else{        
            DataBatch[_DataBatchId].status = DataStatus.REJECTED;
            RejectedBatchsCounter += 1;
        }

        // ---------------- GLOBAL STATE UPDATE ----------------
        AllTxsCounter += 1;
        NotCommitedCounter += DataBatch[_DataBatchId].uncommited_workers;
        NotRevealedCounter += DataBatch[_DataBatchId].unrevealed_workers;

        emit _SpotAccepted(SpotsMapping[_DataBatchId].ipfs_hash, SpotsMapping[_DataBatchId].author);
    }
    


    /* 
    Allocate last data batch to be checked by K out N currently available workers.
     */
    function AllocateWork() public  {        
        require(DataBatch[AllocatedBatchCursor].complete, "Can't allocate work, the current batch is not complete");
        require(DataBatch[AllocatedBatchCursor].allocated_to_work == false, "Can't allocate work, the current batch is already allocated");
        uint256 selected_k = Math.max( Math.min(availableWorkers.length, CONSENSUS_WORKER_SIZE), MIN_CONSENSUS_WORKER_COUNT); // pick at most CONSENSUS_WORKER_SIZE workers, minimum 1.
        uint256 n = availableWorkers.length;

        if((block.timestamp - LastAllocationTime) >= INTER_ALLOCATION_DURATION){
                
            ///////////////////////////// BATCH UPDATE STATE /////////////////////////////
            DataBatch[AllocatedBatchCursor].unrevealed_workers = selected_k;
            DataBatch[AllocatedBatchCursor].uncommited_workers = selected_k;
            
            uint256 _commitEndDate = block.timestamp.add(COMMIT_ROUND_DURATION);
            uint256 _revealEndDate = _commitEndDate.add(REVEAL_ROUND_DURATION);
            DataBatch[AllocatedBatchCursor].commitEndDate = _commitEndDate;
            DataBatch[AllocatedBatchCursor].revealEndDate = _revealEndDate;
            DataBatch[AllocatedBatchCursor].allocated_to_work = true;
            //////////////////////////////////////////////////////////////////////////////
            
            require(selected_k>=1 && n>=1, "Fail during allocation: not enough workers");
            uint256[] memory selected_workers_idx = random_selection(selected_k, n);
            address[] memory selected_workers_addresses = new address[](selected_workers_idx.length);

            for(uint i = 0; i<selected_workers_idx.length; i++){
                selected_workers_addresses[i] = availableWorkers[ selected_workers_idx[i] ];
            }

            for(uint i = 0; i<selected_workers_idx.length; i++){      
                address selected_worker_ = selected_workers_addresses[i];
                WorkerState storage worker_state = WorkersState[selected_worker_];
                ///// worker swapping from available to busy, not to be picked again while working.            
                
                PopFromAvailableWorkers(selected_worker_);
                if(!isInBusyWorkers(selected_worker_)){
                    busyWorkers.push(selected_worker_); //set worker as busy
                }
                WorkersPerBatch[AllocatedBatchCursor].push(selected_worker_);
                ///// allocation
                worker_state.allocated_work_batch = AllocatedBatchCursor;
                worker_state.has_completed_work = false;
                emit _WorkAllocated(AllocatedBatchCursor, selected_worker_);
            }
            
            LastAllocationTime = block.timestamp;
            AllocatedBatchCursor = AllocatedBatchCursor.add(1);
            AllTxsCounter += 1;
        }
    }

    /* To know if new work is available for worker's address user_ */
    function IsNewWorkAvailable(address user_) public view returns(bool) {
        bool new_work_available = false;
        WorkerState memory user_state =  WorkersState[user_];
        if (user_state.has_completed_work == false && DataEnded(user_state.allocated_work_batch) == false ){
            new_work_available = true;
        }
        return new_work_available;
    }

    /* Get newest work */
    function GetCurrentWork(address user_) public view returns(uint256) {
        WorkerState memory user_state =  WorkersState[user_];
        return user_state.allocated_work_batch;
    }


    // ==============================================================================================================================
    // ====================================================== SPOTTING  =============================================================
    // ==============================================================================================================================


    function SpotData(
        string[] memory file_hashs,
        string[] calldata URL_domains,
        uint256 item_count_,
        string memory extra_
        )
    public topUpSFuel returns (uint256 Dataid_)    
    {
        // require(file_hashs.length == URL_domains.length, "SpotData: file_hashs and URL_domains must be of same length");
        // //_numTokens The number of tokens to be committed towards the target SpottedData
        uint256 _numTokens = MIN_STAKE;
        
        // // if msg.sender doesn't have enough voting rights,
        // // request for enough voting rights
        if (SpotStakedTokenBalance[msg.sender] < MIN_STAKE) {
            uint256 remainder = _numTokens.sub(SpotStakedTokenBalance[msg.sender]);
            requestVotingRights(remainder);
        }
        for(uint256 i=0; i < file_hashs.length; i++){
            string memory file_hash = file_hashs[i];
            string memory URL_domain_ = URL_domains[i];

            // make sure msg.sender has enough voting rights
            // require(SpotStakedTokenBalance[msg.sender] >= _numTokens, "user must have enough voting rights aka allocated stake");
            // prevent user from committing a secretHash of 0
            // bytes memory s1bytes = bytes(file_hash);
            // require(s1bytes.length != 0, "file_hash length must be != 0");
            
            
            userSubmissions[msg.sender].push(DataNonce);

            SpotsMapping[DataNonce] = SpottedData({
                ipfs_hash: file_hash,
                author: msg.sender,
                timestamp: block.timestamp,
                item_count: item_count_,
                URL_domain: URL_domain_,
                extra: extra_,
                status: DataStatus.TBD
            });

            // UPDATE STREAMING DATA BATCH STRUCTURE
            BatchMetadata storage current_data_batch = DataBatch[LastBatchCounter];
            if(current_data_batch.counter < DATA_BATCH_SIZE){
                current_data_batch.counter += 1;
            }
            if(current_data_batch.counter >= DATA_BATCH_SIZE)
            { // batch is complete trigger new work round, new batch
                current_data_batch.complete = true;
                current_data_batch.checked = false;
                LastBatchCounter += 1;
                DataBatch[LastBatchCounter].start_idx = DataNonce;
            }

            TriggerNextEpoch();
            DataNonce = DataNonce + 1;
            emit _SpotSubmitted(DataNonce, file_hash, URL_domain_, msg.sender);
            
        }
        AllTxsCounter += 1;
        return DataNonce;
    }





    // =================
    // VOTING INTERFACE:
    // =================

    /**
    @notice Commits spot-check-vote using hash of choice and secret salt to conceal spot-check-vote until reveal
    @param _DataBatchId Integer identifier associated with target SpottedData
    @param _secretHash Commit keccak256 hash of voter's choice and salt (tightly packed in this order)
    // @ _prevDataID The ID of the SpottedData that the user has voted the maximum number of tokens in which is still less than or equal to numTokens
    */
    
    function commitSpotCheck(uint256 _DataBatchId, bytes32 _secretHash, string memory newIPFSHash, uint256 _BatchCount, string memory _From) public topUpSFuel {
        require(commitPeriodActive(_DataBatchId), "commit period needs to be open for this batchId");
        require(!UserChecksCommits[msg.sender][_DataBatchId], "User has already commited to this batchId");
        require(isWorkerAllocatedToBatch(_DataBatchId, msg.sender), "User needs to be allocated to this batch to commit on it");

        //_numTokens The number of tokens to be committed towards the target SpottedData
        uint256 _numTokens = MIN_STAKE;
        
        // if msg.sender doesn't have enough voting rights,
        // request for enough voting rights
        if (SpotStakedTokenBalance[msg.sender] < _numTokens) {
            uint256 remainder = _numTokens.sub(SpotStakedTokenBalance[msg.sender]);
            requestVotingRights(remainder);
        }

        // make sure msg.sender has enough voting rights
        require(SpotStakedTokenBalance[msg.sender] >= _numTokens, "user must have enough voting rights aka allocated stake");

        uint256 _prevDataID = 0;

        // Check if _prevDataID exists in the user's DLL or if _prevDataID is 0
        require(_prevDataID == 0 || dllMap[msg.sender].contains(_prevDataID),"Error:  _prevDataID exists in the user's DLL or if _prevDataID is 0");

        uint256 nextDataID = dllMap[msg.sender].getNext(_prevDataID);

        // edge case: in-place update
        if (nextDataID == _DataBatchId) {
            nextDataID = dllMap[msg.sender].getNext(_DataBatchId);
        }

        require(validPosition(_prevDataID, nextDataID, msg.sender, _numTokens), "not a valid position");
        dllMap[msg.sender].insert(_prevDataID, _DataBatchId, nextDataID);

        bytes32 UUID = attrUUID(msg.sender, _DataBatchId);
        
        
        store.setAttribute(UUID,  "numTokens", _numTokens);
        store.setAttribute(UUID, "commitHash", uint256(_secretHash));
        UserNewFiles[_DataBatchId][msg.sender] = newIPFSHash;
        UserBatchCounts[_DataBatchId][msg.sender] = _BatchCount;
        UserBatchFrom[_DataBatchId][msg.sender] = _From;


        // ----------------------- WORKER STATE UPDATE -----------------------
        WorkerState storage worker_state = WorkersState[msg.sender];
        DataBatch[_DataBatchId].uncommited_workers = DataBatch[_DataBatchId].uncommited_workers.sub(1);
        worker_state.last_interaction_date = block.timestamp;    
        UserChecksCommits[msg.sender][_DataBatchId] = true;

        AllTxsCounter += 1;
        emit _SpotCheckCommitted(_DataBatchId, _numTokens, msg.sender);
    }
    

    /**
    @notice Reveals spot-check-vote with choice and secret salt used in generating commitHash to attribute committed tokens
    @param _DataBatchId Integer identifier associated with target SpottedData
    @param _voteOption SpotCheck choice used to generate commitHash for associated SpottedData
    @param _salt Secret number used to generate commitHash for associated SpottedData
    */
    function revealSpotCheck(uint256 _DataBatchId, uint256 _voteOption, uint256 _salt) topUpSFuel public {
        // Make sure the reveal period is active
        require(revealPeriodActive(_DataBatchId), "Reveal period not open for this DataID");
        require(UserChecksCommits[msg.sender][_DataBatchId], "User has not commited before, thus can't reveal");
        require(!UserChecksReveals[msg.sender][_DataBatchId], "User has already revealed, thus can't reveal");        
        require(getEncryptedHash(_voteOption, _salt) == getCommitHash(msg.sender, _DataBatchId),
        "Not the same vote than what was commited, impossible to match with given _salt & _voteOption"); // compare resultant hash from inputs to original commitHash
        
        uint256 numTokens = getNumTokens(msg.sender, _DataBatchId);

        if (_voteOption == 1) {// apply numTokens to appropriate SpottedData choice
            DataBatch[_DataBatchId].votesFor += numTokens;
        } else {
            DataBatch[_DataBatchId].votesAgainst += numTokens;
        }

        // ----------------------- USER STATE UPDATE -----------------------
        dllMap[msg.sender].remove(_DataBatchId); // remove the node referring to this spot-check-vote upon reveal
        UserChecksReveals[msg.sender][_DataBatchId] = true;
        UserVotes[_DataBatchId][msg.sender] = _voteOption;
        
        // ----------------------- WORKER STATE UPDATE -----------------------
        WorkerState storage worker_state = WorkersState[msg.sender];
        DataBatch[_DataBatchId].unrevealed_workers = DataBatch[_DataBatchId].unrevealed_workers.sub(1);
        worker_state.has_completed_work = true;
        worker_state.last_interaction_date = block.timestamp;   

        // PUT BACK THE WORKER AS AVAILABLE
        PopFromBusyWorkers(msg.sender);
        
        if(worker_state.registered){ // only if the worker is still registered, of course.
            if(!isInAvailableWorkers(msg.sender) && (worker_state.unregistration_request == false)){
                availableWorkers.push(msg.sender);
            }
        }

        AllTxsCounter += 1;
        emit _SpotCheckRevealed(_DataBatchId, numTokens, DataBatch[_DataBatchId].votesFor, DataBatch[_DataBatchId].votesAgainst, _voteOption, msg.sender);
    }


    // ================================================================================
    //                              STAKING & TOKEN INTERFACE
    // ================================================================================

    /**
    @notice Loads _numTokens ERC20 tokens into the voting contract for one-to-one voting rights
    @dev Assumes that msg.sender has approved voting contract to spend on their behalf
    @param _numTokens The number of votingTokens desired in exchange for ERC20 tokens
    */
    function requestVotingRights(uint256 _numTokens) public {
        require(StakeManager.ProxyStakeAllocate(_numTokens, msg.sender), "Could not request enough allocated stake, requestVotingRights");
        SpotStakedTokenBalance[msg.sender] += _numTokens;
        emit _VotingRightsGranted(_numTokens, msg.sender);
    }
    
    
    /**
    @notice Withdraw _numTokens ERC20 tokens from the voting contract, revoking these voting rights
    @param _numTokens The number of ERC20 tokens desired in exchange for voting rights
    */
    function withdrawVotingRights(uint256 _numTokens) public {
        uint256 availableTokens = SpotStakedTokenBalance[msg.sender].sub(getLockedTokens(msg.sender));
        require(availableTokens >= _numTokens, "availableTokens should be >= _numTokens");
        require(StakeManager.ProxyStakeDeallocate(_numTokens, msg.sender), "Could not withdrawVotingRights through ProxyStakeDeallocate");
        SpotStakedTokenBalance[msg.sender] -= _numTokens;
        emit _VotingRightsWithdrawn(_numTokens, msg.sender);
    }

    
    function getMySystemTokenBalance() public view returns (uint256 tokens) {
        return(uint256(SpotStakedTokenBalance[msg.sender]));
    }
    
    function getSystemTokenBalance(address _user) public view returns (uint256 tokens) {
        return(uint256(SpotStakedTokenBalance[_user]));
    }

    function getAcceptedBatchesCount() public view returns (uint256 count) {
        return(uint256(AcceptedBatchsCounter));
    }

    function getRejectedBatchesCount() public view returns (uint256 count) {
        return(uint256(RejectedBatchsCounter));
    }

    /**
    @dev Unlocks tokens locked in unrevealed spot-check-vote where SpottedData has ended
    @param _DataBatchId Integer identifier associated with the target SpottedData
    */
    function rescueTokens(uint256 _DataBatchId) public {
        require(DataBatch[_DataBatchId].status == DataStatus.APPROVED, "given DataBatch should be APPROVED, and it is not");
        require(dllMap[msg.sender].contains(_DataBatchId), "dllMap: does not cointain _DataBatchId for the msg sender");

        dllMap[msg.sender].remove(_DataBatchId);
        emit _TokensRescued(_DataBatchId, msg.sender);
    }

    /**
    @dev Unlocks tokens locked in unrevealed spot-check-votes where Datas have ended
    @param _DataBatchIDs Array of integer identifiers associated with the target Datas
    */
    function rescueTokensInMultipleDatas(uint256[] memory _DataBatchIDs) public {
        // loop through arrays, rescuing tokens from all
        for (uint256 i = 0; i < _DataBatchIDs.length; i++) {
            rescueTokens(_DataBatchIDs[i]);
        }
    }

    

    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    //                              STATE Getters
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    // --------------------------------------------------------------------------------------------------------------------------------------------------------

    
    function getIPFShashesForBatch(uint256 _DataBatchId) public view returns (string[] memory)  {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");
        BatchMetadata memory batch_ = DataBatch[_DataBatchId];
        uint256 batch_size = batch_.counter;

        string[] memory ipfs_hash_list = new string[](DATA_BATCH_SIZE);

        for(uint256 i=0; i < batch_size; i++){
            uint256 k = batch_.start_idx + i;
            string memory ipfs_hash_ = SpotsMapping[k].ipfs_hash;
            ipfs_hash_list[i] = ipfs_hash_;
        }

        return ipfs_hash_list;
    }



    function getDomainsForBatch(uint256 _DataBatchId) public view returns (string[] memory)  {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");
        BatchMetadata memory batch_ = DataBatch[_DataBatchId];
        uint256 batch_size = batch_.counter;

        string[] memory ipfs_hash_list = new string[](DATA_BATCH_SIZE);

        for(uint256 i=0; i < batch_size; i++){
            uint256 k = batch_.start_idx + i;
            string memory ipfs_hash_ = SpotsMapping[k].URL_domain;
            ipfs_hash_list[i] = ipfs_hash_;
        }

        return ipfs_hash_list;
    }
    
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    //                              Data HELPERS
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    // --------------------------------------------------------------------------------------------------------------------------------------------------------
    
    function getActiveWorkersCount() public view returns (uint256 numWorkers) {
        return(uint256(availableWorkers.length+busyWorkers.length));
    }



    /**
    @dev Compares previous and next SpottedData's committed tokens for sorting purposes
    @param _prevID Integer identifier associated with previous SpottedData in sorted order
    @param _nextID Integer identifier associated with next SpottedData in sorted order
    @param _voter Address of user to check DLL position for
    @param _numTokens The number of tokens to be committed towards the SpottedData (used for sorting)
    @return APPROVED Boolean indication of if the specified position maintains the sort
    */
    function validPosition(uint256 _prevID, uint256 _nextID, address _voter, uint256 _numTokens) public view returns (bool APPROVED) {
        bool prevValid = (_numTokens >= getNumTokens(_voter, _prevID));
        // if next is zero node, _numTokens does not need to be greater
        bool nextValid = (_numTokens <= getNumTokens(_voter, _nextID) || _nextID == 0);
        return prevValid && nextValid;
    }



    /**
    @notice Determines if proposal has passed
    @dev Check if votesFor out of totalSpotChecks exceeds votesQuorum (requires DataEnded)
    @param _DataBatchId Integer identifier associated with target SpottedData
    */
    function isPassed(uint256 _DataBatchId)  public view returns (bool passed) {
        BatchMetadata memory batch_ = DataBatch[_DataBatchId];
        return (100 * batch_.votesFor) > (VOTE_QUORUM * (batch_.votesFor + batch_.votesAgainst));
    }

    // /**
    // @param _DataBatchId Integer identifier associated with target SpottedData
    // @param _salt Arbitrarily chosen integer used to generate secretHash
    // @return correctSpotChecks Number of tokens voted for winning option
    // */
    // function getNumPassingTokens(address _voter, uint256 _DataBatchId, uint256 _salt) public view returns (uint256 correctSpotChecks) {
    //     require(DataEnded(_DataBatchId), "_DataBatchId checking vote must have ended");
    //     require(UserChecksReveals[_voter][_DataBatchId], "user must have revealed in this given Batch");
        

    //     uint256 winningChoice = isPassed(_DataBatchId) ? 1 : 0;
    //     bytes32 winnerHash = keccak256(abi.encodePacked(winningChoice, _salt));
    //     bytes32 commitHash = getCommitHash(_voter, _DataBatchId);

    //     require(winnerHash == commitHash, "getNumPassingTokens: hashes must be equal");

    //     return getNumTokens(_voter, _DataBatchId);
    // }

    // /**
    // @dev Gets the total winning spot-check-votes for reward distribution purposes
    // @param _DataBatchId Integer identifier associated with target SpottedData
    // @return numTokens of spot-check-votes committed to the winning option for specified SpottedData
    // */
    // function getTotalNumberOfTokensForWinningOption(uint256 _DataBatchId) public view returns (uint256 numTokens) {
    //     require(DataEnded(_DataBatchId), "Data must have ended");

    //     if (isPassed(_DataBatchId))
    //         return DataBatch[_DataBatchId].votesFor;
    //     else
    //         return DataBatch[_DataBatchId].votesAgainst;
    // }

    /**
    @notice Determines if SpottedData is over
    @dev Checks isExpired for specified SpottedData's revealEndDate
    @return ended Boolean indication of whether Dataing period is over
    */
    function DataEnded(uint256 _DataBatchId) public view returns (bool ended) {
        require(DataExists(_DataBatchId), "Data must exist");

        return isExpired(DataBatch[_DataBatchId].revealEndDate);
    }
    
    /**
    @notice getUserDatas
    @return user_Datas the array of Datas started by the user
    */
    function getUserDatas(address user) public view returns (uint256[] memory user_Datas) {

        return userSubmissions[user];
    }
    
    /**
    @notice getLastUserDataId
    @return DataId of the last Dataed a user started
    */
    function getLastUserDataId(address user) public view returns (uint256 DataId) {
        uint256[] memory userDatas = userSubmissions[user];

        return  userDatas[ userDatas.length - 1 ];
    }
    
    /**
    @notice getLastDataId
    @return DataId of the last Dataed a user started
    */
    function getLastDataId() public view returns (uint256 DataId) {
        return  DataNonce;
    }

    /**
    @notice getLastBatchId
    @return LastBatchId of the last Dataed a user started
    */
    function getLastBatchId() public view returns (uint256 LastBatchId) {
        return  LastBatchCounter;
    }
    
    /**
    @notice getLastBachDataId
    @return LastCheckedBatchId of the last Dataed a user started
    */
    function getLastCheckedBatchId() public view returns (uint256 LastCheckedBatchId) {
        return  BatchCheckingCursor;
    }
    
    /**
    @notice getLastAllocatedBatchId
    @return LastAllocatedBatchId of the last Dataed a user started
    */
    function getLastAllocatedBatchId() public view returns (uint256 LastAllocatedBatchId) {
        return  AllocatedBatchCursor;
    }
    
    
    /**
    @notice getLastBachDataId
    @return batch of the last Dataed a user started
    */
    function getBatchByID(uint256 _DataBatchId) public view returns (BatchMetadata memory batch) {
        require(DataExists(_DataBatchId));
        return  DataBatch[_DataBatchId];
    }

    /**
    @notice getLastBachDataId
    @return batch of the last Dataed a user started
    */
    function getBatchIPFSFileByID(uint256 _DataBatchId) public view returns (string memory batch) {
        require(DataExists(_DataBatchId));
        return  DataBatch[_DataBatchId].batchIPFSfile;
    }

    
    /**
    @notice getLastBachDataId
    @return data of the last Dataed a user started
    */
    function getDataByID(uint256 _DataId) public view returns (SpottedData memory data) {
        return  SpotsMapping[_DataId];
    }
    
    /**
    @notice getCounter
    @return Counter of the last Dataed a user started
    */
    function getTxCounter() public view returns (uint256 Counter) {
        return  AllTxsCounter;
    }

    /**
    @notice getLastBachDataId
    @return WorkEpoch of the last Dataed a user started
    */
    function getCurrentWorkEpoch() public view returns (uint256 WorkEpoch) {
        return  CurrentWorkEpoch;
    }
    /**
    @notice Determines DataCommitEndDate
    @return commitEndDate indication of whether Dataing period is over
    */
    function DataCommitEndDate(uint256 _DataBatchId) public view returns (uint256 commitEndDate) {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        return DataBatch[_DataBatchId].commitEndDate;
    }
    
    
    /**
    @notice Determines DataRevealEndDate
    @return revealEndDate indication of whether Dataing period is over
    */
    function DataRevealEndDate(uint256 _DataBatchId) public view returns (uint256 revealEndDate) {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        return DataBatch[_DataBatchId].revealEndDate;
    }
    
    /**
    @notice Checks if the commit period is still active for the specified SpottedData
    @dev Checks isExpired for the specified SpottedData's commitEndDate
    @param _DataBatchId Integer identifier associated with target SpottedData
    @return active Boolean indication of isCommitPeriodActive for target SpottedData
    */
    function commitPeriodActive(uint256 _DataBatchId) public view returns (bool active) {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        return !isExpired(DataBatch[_DataBatchId].commitEndDate) && (DataBatch[_DataBatchId].uncommited_workers > 0);
    }

    /**
    @notice Checks if the reveal period is still active for the specified SpottedData
    @dev Checks isExpired for the specified SpottedData's revealEndDate
    @param _DataBatchId Integer identifier associated with target SpottedData
    */
    function revealPeriodActive(uint256 _DataBatchId) public view returns (bool active) {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        return !isExpired(DataBatch[_DataBatchId].revealEndDate) && !commitPeriodActive(_DataBatchId);
    }

    /**
    @dev Checks if user has committed for specified SpottedData
    @param _voter Address of user to check against
    @param _DataBatchId Integer identifier associated with target SpottedData
    @return committed Boolean indication of whether user has committed
    */
    function didCommit(address _voter, uint256 _DataBatchId) public view returns (bool committed) {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        // return SpotsMapping[_DataBatchId].didCommit[_voter];
        return UserChecksCommits[_voter][_DataBatchId];
    }

    /**
    @dev Checks if user has revealed for specified SpottedData
    @param _voter Address of user to check against
    @param _DataBatchId Integer identifier associated with target SpottedData
    @return revealed Boolean indication of whether user has revealed
    */
    function didReveal(address _voter, uint256 _DataBatchId) public view returns (bool revealed) {
        require(DataExists(_DataBatchId), "_DataBatchId must exist");

        // return SpotsMapping[_DataBatchId].didReveal[_voter];
        return UserChecksReveals[_voter][_DataBatchId];
    }

    /**
    @dev Checks if a SpottedData exists
    @param _DataBatchId The DataID whose existance is to be evaluated.
    @return exists Boolean Indicates whether a SpottedData exists for the provided DataID
    */
    function DataExists(uint256 _DataBatchId) public view returns  (bool exists) {
        return (_DataBatchId <= LastBatchCounter);
    }

    function AmIRegistered()  public view returns (bool passed) {
        return WorkersState[msg.sender].registered;
    }

    function isWorkerRegistered(address _worker)  public view returns (bool passed) {
        return WorkersState[_worker].registered;
    }


    // ------------------------------------------------------------------------------------------------------------
    // DOUBLE-LINKED-LIST HELPERS:
    // ------------------------------------------------------------------------------------------------------------

    /**
    @dev Gets the bytes32 commitHash property of target SpottedData
    @param _voter Address of user to check against
    @param _DataBatchId Integer identifier associated with target SpottedData
    @return commitHash Bytes32 hash property attached to target SpottedData
    */
    function getCommitHash(address _voter, uint256 _DataBatchId)  public view returns (bytes32 commitHash) {
        return bytes32(store.getAttribute(attrUUID(_voter, _DataBatchId), "commitHash"));
    }

    /**
    @dev Gets the bytes32 commitHash property of target SpottedData
    @param _voteOption vote Option
    @param _salt is the salt
    @return keccak256hash Bytes32 hash property attached to target SpottedData
    */
    function getEncryptedHash(uint256 _voteOption, uint256 _salt)  public pure returns (bytes32 keccak256hash) {
        return keccak256(abi.encodePacked(_voteOption, _salt));
    }

    /**
    @dev Gets the bytes32 commitHash property of target FormattedData
    @param _hash ipfs hash of aggregated data in a string
    @param _salt is the salt
    @return keccak256hash Bytes32 hash property attached to target FormattedData
    */
    function getEncryptedStringHash(string calldata _hash, uint256 _salt) public pure returns (bytes32 keccak256hash){
        return keccak256(abi.encode(_hash, _salt));
    }


    /**
    @dev Wrapper for getAttribute with attrName="numTokens"
    @param _voter Address of user to check against
    @param _DataBatchId Integer identifier associated with target SpottedData
    @return numTokens Number of tokens committed to SpottedData in sorted SpottedData-linked-list
    */
    function getNumTokens(address _voter, uint256 _DataBatchId)  public view returns (uint256 numTokens) {
        return store.getAttribute(attrUUID(_voter, _DataBatchId), "numTokens");
    }

    /**
    @dev Gets top element of sorted SpottedData-linked-list
    @param _voter Address of user to check against
    @return DataID Integer identifier to SpottedData with maximum number of tokens committed to it
    */
    function getLastNode(address _voter)  public view returns (uint256 DataID) {
        return dllMap[_voter].getPrev(0);
    }

    /**
    @dev Gets the numTokens property of getLastNode
    @param _voter Address of user to check against
    @return numTokens Maximum number of tokens committed in SpottedData specified
    */
    function getLockedTokens(address _voter)  public view returns (uint256 numTokens) {
        return getNumTokens(_voter, getLastNode(_voter));
    }

    // /*
    // @dev Takes the last node in the user's DLL and iterates backwards through the list searching
    // for a node with a value less than or equal to the provided _numTokens value. When such a node
    // is found, if the provided _DataBatchId matches the found nodeID, this operation is an in-place
    // update. In that case, return the previous node of the node being updated. Otherwise return the
    // first node that was found with a value less than or equal to the provided _numTokens.
    // @param _voter The voter whose DLL will be searched
    // @param _numTokens The value for the numTokens attribute in the node to be inserted
    // @return the node which the propoded node should be inserted after
    // */
    // function getInsertPointForNumTokens(address _voter, uint256 _numTokens, uint256 _DataBatchId) public view  returns (uint256 prevNode) {
    //   // Get the last node in the list and the number of tokens in that node
    //   uint256 nodeID = getLastNode(_voter);
    //   uint256 tokensInNode = getNumTokens(_voter, nodeID);

    //   // Iterate backwards through the list until reaching the root node
    //   while(nodeID != 0) {
    //     // Get the number of tokens in the current node
    //     tokensInNode = getNumTokens(_voter, nodeID);
    //     if(tokensInNode <= _numTokens) { // We found the insert point!
    //       if(nodeID == _DataBatchId) {
    //         // This is an in-place update. Return the prev node of the node being updated
    //         nodeID = dllMap[_voter].getPrev(nodeID);
    //       }
    //       // Return the insert point
    //       return nodeID; 
    //     }
    //     // We did not find the insert point. Continue iterating backwards through the list
    //     nodeID = dllMap[_voter].getPrev(nodeID);
    //   }

    //   // The list is empty, or a smaller value than anything else in the list is being inserted
    //   return nodeID;
    // }

    // ----------------
    // GENERAL HELPERS:
    // ----------------

    /**
    @dev Checks if an expiration date has been reached
    @param _terminationDate Integer timestamp of date to compare current timestamp with
    @return expired Boolean indication of whether the terminationDate has passed
    */
    function isExpired(uint256 _terminationDate)  public view returns (bool expired) {
        return (block.timestamp > _terminationDate);
    }
    
    
    /**
    @dev Generates an identifier which associates a user and a SpottedData together
    @param _DataBatchId Integer identifier associated with target SpottedData
    @return UUID Hash which is deterministic from _user and _DataBatchId
    */
    function attrUUID(address _user, uint256 _DataBatchId) public pure returns (bytes32 UUID) {
        return keccak256(abi.encodePacked(_user, _DataBatchId));
    }
}
