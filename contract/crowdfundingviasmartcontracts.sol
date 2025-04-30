// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CrowdfundingPro is Ownable, Pausable {
    using SafeMath for uint256;

    struct Milestone {
        uint256 amount;
        string description;
        bool isCompleted;
    }

    struct Campaign {
        address payable creator;
        uint256 goal;
        uint256 amountRaised;
        bool isCompleted;
        bool isRefundable;
        uint256 minContribution;
        uint256 maxContribution;
        uint256 deadline;
        string title;
        string description;
        string imageHash;
        mapping(address => uint256) contributions;
        address[] contributors;
        Milestone[] milestones;
        bool hasWithdrawalLimit;
        uint256 withdrawalLimit;
        uint256 totalWithdrawn;
        uint256 category; // 1=Tech, 2=Art, 3=Charity, etc.
        bool isVerified;
        address tokenAddress; // Address of ERC20 token used for funding (address(0) for ETH)
        uint256 backerCount;
        bool allowPartialWithdrawal;
        uint256 lastWithdrawalTime;
        uint256 withdrawalInterval;
    }

    uint256 private campaignCounter;
    mapping(uint256 => Campaign) private campaigns;
    uint256 public platformFee = 250; // Represents 2.5% (250 basis points)
    mapping(address => uint256[]) private userCampaigns;
    mapping(address => bool) private verifiedCreators;
    address[] private verifiedCreatorList;
    uint256 public totalPlatformFeesCollected;
    mapping(address => bool) public allowedTokens;
    uint256 public promotionDuration = 7 days;
    mapping(uint256 => uint256) public promotionEndTime;
    mapping(uint256 => uint256) public campaignCreationTime;

    event CampaignCreated(uint256 indexed campaignId, address indexed creator, uint256 goal, uint256 deadline);
    event ContributionReceived(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignSuccessful(uint256 indexed campaignId);
    event GoalModified(uint256 indexed campaignId, uint256 newGoal);
    event RefundIssued(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event ExcessWithdrawn(uint256 indexed campaignId, uint256 amount);
    event CampaignCancelled(uint256 indexed campaignId);
    event DeadlineExtended(uint256 indexed campaignId, uint256 newDeadline);
    event PlatformFeeUpdated(uint256 newFee);
    event CampaignDetailsUpdated(uint256 indexed campaignId);
    event EmergencyStopActivated(uint256 indexed campaignId);
    event MilestoneAdded(uint256 indexed campaignId, uint256 amount, string description);
    event MilestoneCompleted(uint256 indexed campaignId, uint256 milestoneId);
    event CreatorVerified(address indexed creator);
    event CreatorUnverified(address indexed creator);
    event CampaignVerified(uint256 indexed campaignId);
    event CampaignPromoted(uint256 indexed campaignId, uint256 promotionFee);
    event WithdrawalLimitSet(uint256 indexed campaignId, uint256 limit);
    event CategoryChanged(uint256 indexed campaignId, uint256 newCategory);
    event FundsRecovered(address indexed recipient, uint256 amount);
    event TokenContribution(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event PartialWithdrawal(uint256 indexed campaignId, uint256 amount);
    event WithdrawalIntervalSet(uint256 indexed campaignId, uint256 interval);
    event AllowPartialWithdrawalChanged(uint256 indexed campaignId, bool allowed);
    event CampaignTokenChanged(uint256 indexed campaignId, address tokenAddress);

    modifier campaignExists(uint256 _campaignId) {
        require(_campaignId > 0 && _campaignId <= campaignCounter, "Campaign does not exist");
        _;
    }

    modifier onlyCreator(uint256 _campaignId) {
        require(msg.sender == campaigns[_campaignId].creator, "Only campaign creator");
        _;
    }

    modifier onlyVerifiedCreator() {
        require(verifiedCreators[msg.sender], "Only verified creators");
        _;
    }

    // ========== CORE FUNCTIONS ==========

    function createCampaign(
        uint256 _goal,
        uint256 _minContribution,
        uint256 _maxContribution,
        uint256 _durationInDays,
        string memory _title,
        string memory _description,
        string memory _imageHash,
        uint256 _category,
        bool _hasWithdrawalLimit,
        uint256 _withdrawalLimit,
        address _tokenAddress,
        bool _allowPartialWithdrawal,
        uint256 _withdrawalInterval
    ) external whenNotPaused {
        require(_goal > 0, "Goal must be greater than zero");
        require(_minContribution > 0, "Minimum contribution must be greater than zero");
        require(_maxContribution >= _minContribution, "Max contribution must be >= min");
        require(_durationInDays > 0, "Duration must be greater than zero");
        require(bytes(_title).length > 0, "Title is required");
        if (_hasWithdrawalLimit) {
            require(_withdrawalLimit > 0, "Withdrawal limit must be greater than zero");
        }
        if (_tokenAddress != address(0)) {
            require(allowedTokens[_tokenAddress], "Token not allowed");
        }
        if (_withdrawalInterval > 0) {
            require(_withdrawalInterval >= 1 days, "Interval must be at least 1 day");
        }

        campaignCounter++;
        Campaign storage c = campaigns[campaignCounter];
        c.creator = payable(msg.sender);
        c.goal = _goal;
        c.minContribution = _minContribution;
        c.maxContribution = _maxContribution;
        c.deadline = block.timestamp + (_durationInDays * 1 days);
        c.title = _title;
        c.description = _description;
        c.imageHash = _imageHash;
        c.category = _category;
        c.hasWithdrawalLimit = _hasWithdrawalLimit;
        c.withdrawalLimit = _withdrawalLimit;
        c.isVerified = verifiedCreators[msg.sender];
        c.tokenAddress = _tokenAddress;
        c.allowPartialWithdrawal = _allowPartialWithdrawal;
        c.withdrawalInterval = _withdrawalInterval;
        campaignCreationTime[campaignCounter] = block.timestamp;

        userCampaigns[msg.sender].push(campaignCounter);

        emit CampaignCreated(campaignCounter, msg.sender, _goal, c.deadline);
    }

    function contribute(uint256 _campaignId) external payable whenNotPaused campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(c.tokenAddress == address(0), "This campaign accepts token contributions");
        require(msg.value > 0, "Contribution must be greater than zero");
        require(!c.isCompleted, "Campaign has ended");
        require(msg.value >= c.minContribution, "Contribution below minimum");
        require(msg.value <= c.maxContribution, "Contribution exceeds maximum");
        require(block.timestamp <= c.deadline, "Campaign deadline passed");

        _processContribution(_campaignId, msg.value);
    }

    function contributeWithToken(uint256 _campaignId, uint256 _amount) external whenNotPaused campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(c.tokenAddress != address(0), "This campaign accepts ETH contributions");
        require(_amount > 0, "Contribution must be greater than zero");
        require(!c.isCompleted, "Campaign has ended");
        require(_amount >= c.minContribution, "Contribution below minimum");
        require(_amount <= c.maxContribution, "Contribution exceeds maximum");
        require(block.timestamp <= c.deadline, "Campaign deadline passed");

        IERC20 token = IERC20(c.tokenAddress);
        require(token.transferFrom(msg.sender, address(this), _amount), "Token transfer failed");

        _processContribution(_campaignId, _amount);
        emit TokenContribution(_campaignId, msg.sender, _amount);
    }

    function _processContribution(uint256 _campaignId, uint256 _amount) private {
        Campaign storage c = campaigns[_campaignId];
        
        if (c.contributions[msg.sender] == 0) {
            c.contributors.push(msg.sender);
            c.backerCount++;
        }
        c.contributions[msg.sender] += _amount;
        c.amountRaised += _amount;

        emit ContributionReceived(_campaignId, msg.sender, _amount);

        if (c.amountRaised >= c.goal) {
            c.isCompleted = true;
            uint256 feeAmount = (c.amountRaised * platformFee) / 10000;
            uint256 payout = c.amountRaised - feeAmount;
            
            if (c.tokenAddress == address(0)) {
                c.creator.transfer(payout);
                payable(owner()).transfer(feeAmount);
            } else {
                IERC20 token = IERC20(c.tokenAddress);
                require(token.transfer(c.creator, payout), "Payout transfer failed");
                require(token.transfer(owner(), feeAmount), "Fee transfer failed");
            }
            
            totalPlatformFeesCollected += feeAmount;
            emit CampaignSuccessful(_campaignId);
        }
    }

    // ========== CAMPAIGN MANAGEMENT FUNCTIONS ==========

    function modifyGoal(uint256 _campaignId, uint256 _newGoal) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Cannot modify completed campaign");
        require(_newGoal > c.amountRaised, "Goal must exceed amount raised");

        c.goal = _newGoal;
        emit GoalModified(_campaignId, _newGoal);
    }

    function enableRefunds(uint256 _campaignId) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Completed campaign");

        c.isRefundable = true;
    }

    function requestRefund(uint256 _campaignId) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(c.isRefundable, "Refunds not available");
        require(!c.isCompleted, "Campaign already succeeded");

        uint256 refundAmount = c.contributions[msg.sender];
        require(refundAmount > 0, "No contribution to refund");

        c.contributions[msg.sender] = 0;
        c.amountRaised -= refundAmount;
        
        if (c.tokenAddress == address(0)) {
            payable(msg.sender).transfer(refundAmount);
        } else {
            IERC20 token = IERC20(c.tokenAddress);
            require(token.transfer(msg.sender, refundAmount), "Refund transfer failed");
        }

        emit RefundIssued(_campaignId, msg.sender, refundAmount);
    }

    function withdrawSurplus(uint256 _campaignId) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(c.isCompleted, "Campaign not completed");

        uint256 excess = c.amountRaised > c.goal ? c.amountRaised - c.goal : 0;
        require(excess > 0, "No excess to withdraw");

        c.amountRaised -= excess;
        
        if (c.tokenAddress == address(0)) {
            c.creator.transfer(excess);
        } else {
            IERC20 token = IERC20(c.tokenAddress);
            require(token.transfer(c.creator, excess), "Transfer failed");
        }

        emit ExcessWithdrawn(_campaignId, excess);
    }

    function withdrawPartialFunds(uint256 _campaignId, uint256 _amount) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(c.allowPartialWithdrawal, "Partial withdrawals not allowed");
        require(!c.isCompleted, "Campaign completed");
        require(c.amountRaised >= _amount, "Insufficient funds");
        
        if (c.withdrawalInterval > 0) {
            require(block.timestamp >= c.lastWithdrawalTime + c.withdrawalInterval, "Withdrawal interval not passed");
        }
        
        if (c.hasWithdrawalLimit) {
            require(c.totalWithdrawn + _amount <= c.withdrawalLimit, "Exceeds withdrawal limit");
        }
        
        uint256 feeAmount = (_amount * platformFee) / 10000;
        uint256 payout = _amount - feeAmount;
        
        c.amountRaised -= _amount;
        c.totalWithdrawn += _amount;
        c.lastWithdrawalTime = block.timestamp;
        
        if (c.tokenAddress == address(0)) {
            c.creator.transfer(payout);
            payable(owner()).transfer(feeAmount);
        } else {
            IERC20 token = IERC20(c.tokenAddress);
            require(token.transfer(c.creator, payout), "Transfer failed");
            require(token.transfer(owner(), feeAmount), "Fee transfer failed");
        }
        
        totalPlatformFeesCollected += feeAmount;
        emit PartialWithdrawal(_campaignId, _amount);
    }

    function cancelCampaign(uint256 _campaignId) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");

        c.isCompleted = true;
        for (uint256 i = 0; i < c.contributors.length; i++) {
            address contributor = c.contributors[i];
            uint256 contribution = c.contributions[contributor];
            if (contribution > 0) {
                c.contributions[contributor] = 0;
                
                if (c.tokenAddress == address(0)) {
                    payable(contributor).transfer(contribution);
                } else {
                    IERC20 token = IERC20(c.tokenAddress);
                    require(token.transfer(contributor, contribution), "Refund transfer failed");
                }
                
                emit RefundIssued(_campaignId, contributor, contribution);
            }
        }

        emit CampaignCancelled(_campaignId);
    }

    function extendDeadline(uint256 _campaignId, uint256 _additionalDays) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        require(_additionalDays > 0, "Must extend by at least 1 day");

        c.deadline += _additionalDays * 1 days;
        emit DeadlineExtended(_campaignId, c.deadline);
    }

    function updateCampaignDetails(
        uint256 _campaignId,
        string memory _title,
        string memory _description,
        string memory _imageHash
    ) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        
        if (bytes(_title).length > 0) {
            c.title = _title;
        }
        if (bytes(_description).length > 0) {
            c.description = _description;
        }
        if (bytes(_imageHash).length > 0) {
            c.imageHash = _imageHash;
        }
        
        emit CampaignDetailsUpdated(_campaignId);
    }

    function emergencyStop(uint256 _campaignId) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == owner() || msg.sender == c.creator, "Not authorized");
        require(!c.isCompleted, "Campaign already completed");
        
        c.isRefundable = true;
        emit EmergencyStopActivated(_campaignId);
    }

    // ========== MILESTONE FUNCTIONS ==========

    function addMilestone(
        uint256 _campaignId,
        uint256 _amount,
        string memory _description
    ) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");

        c.milestones.push(Milestone({
            amount: _amount,
            description: _description,
            isCompleted: false
        }));

        emit MilestoneAdded(_campaignId, _amount, _description);
    }

    function completeMilestone(uint256 _campaignId, uint256 _milestoneId) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(_milestoneId < c.milestones.length, "Invalid milestone ID");
        require(!c.milestones[_milestoneId].isCompleted, "Milestone already completed");
        require(c.isCompleted, "Campaign not yet successful");

        Milestone storage m = c.milestones[_milestoneId];
        
        if (c.hasWithdrawalLimit) {
            require(c.totalWithdrawn + m.amount <= c.withdrawalLimit, "Exceeds withdrawal limit");
        }

        uint256 feeAmount = (m.amount * platformFee) / 10000;
        uint256 payout = m.amount - feeAmount;
        
        if (c.tokenAddress == address(0)) {
            c.creator.transfer(payout);
            payable(owner()).transfer(feeAmount);
        } else {
            IERC20 token = IERC20(c.tokenAddress);
            require(token.transfer(c.creator, payout), "Payout transfer failed");
            require(token.transfer(owner(), feeAmount), "Fee transfer failed");
        }
        
        totalPlatformFeesCollected += feeAmount;
        m.isCompleted = true;
        c.totalWithdrawn += m.amount;
        
        emit MilestoneCompleted(_campaignId, _milestoneId);
    }

    // ========== TOKEN MANAGEMENT ==========

    function addAllowedToken(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(!allowedTokens[_token], "Token already allowed");
        
        allowedTokens[_token] = true;
        emit TokenAdded(_token);
    }

    function removeAllowedToken(address _token) external onlyOwner {
        require(allowedTokens[_token], "Token not allowed");
        
        allowedTokens[_token] = false;
        emit TokenRemoved(_token);
    }

    function changeCampaignToken(uint256 _campaignId, address _newToken) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        require(c.amountRaised == 0, "Cannot change token after contributions");
        require(_newToken == address(0) || allowedTokens[_newToken], "Token not allowed");
        
        c.tokenAddress = _newToken;
        emit CampaignTokenChanged(_campaignId, _newToken);
    }

    // ========== WITHDRAWAL SETTINGS ==========

    function setWithdrawalInterval(uint256 _campaignId, uint256 _interval) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        require(_interval == 0 || _interval >= 1 days, "Interval must be at least 1 day or zero");
        
        c.withdrawalInterval = _interval;
        emit WithdrawalIntervalSet(_campaignId, _interval);
    }

    function togglePartialWithdrawal(uint256 _campaignId, bool _allow) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        
        c.allowPartialWithdrawal = _allow;
        emit AllowPartialWithdrawalChanged(_campaignId, _allow);
    }

    function setWithdrawalLimit(uint256 _campaignId, uint256 _limit) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        
        c.hasWithdrawalLimit = true;
        c.withdrawalLimit = _limit;
        
        emit WithdrawalLimitSet(_campaignId, _limit);
    }

    function removeWithdrawalLimit(uint256 _campaignId) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        
        c.hasWithdrawalLimit = false;
        c.withdrawalLimit = 0;
    }

    // ========== VERIFICATION & PROMOTION ==========

    function verifyCreator(address _creator) external onlyOwner {
        require(!verifiedCreators[_creator], "Already verified");
        verifiedCreators[_creator] = true;
        verifiedCreatorList.push(_creator);
        
        // Mark all their campaigns as verified
        uint256[] storage creatorCampaigns = userCampaigns[_creator];
        for (uint256 i = 0; i < creatorCampaigns.length; i++) {
            campaigns[creatorCampaigns[i]].isVerified = true;
        }
        
        emit CreatorVerified(_creator);
    }

    function unverifyCreator(address _creator) external onlyOwner {
        require(verifiedCreators[_creator], "Not verified");
        verifiedCreators[_creator] = false;
        
        // Remove from verifiedCreatorList
        for (uint256 i = 0; i < verifiedCreatorList.length; i++) {
            if (verifiedCreatorList[i] == _creator) {
                verifiedCreatorList[i] = verifiedCreatorList[verifiedCreatorList.length - 1];
                verifiedCreatorList.pop();
                break;
            }
        }
        
        emit CreatorUnverified(_creator);
    }

    function verifyCampaign(uint256 _campaignId) external onlyOwner campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isVerified, "Already verified");
        
        c.isVerified = true;
        emit CampaignVerified(_campaignId);
    }

    function promoteCampaign(uint256 _campaignId, uint256 _promotionFee) 
        external 
        payable 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        require(msg.value == _promotionFee, "Incorrect promotion fee");
        require(_promotionFee > 0, "Promotion fee required");
        
        payable(owner()).transfer(_promotionFee);
        totalPlatformFeesCollected += _promotionFee;
        promotionEndTime[_campaignId] = block.timestamp + promotionDuration;
        
        emit CampaignPromoted(_campaignId, _promotionFee);
    }

    function setPromotionDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0, "Duration must be positive");
        promotionDuration = _duration;
    }

    // ========== CATEGORY MANAGEMENT ==========

    function setCampaignCategory(uint256 _campaignId, uint256 _newCategory) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");
        
        c.category = _newCategory;
        emit CategoryChanged(_campaignId, _newCategory);
    }

    // ========== FUNDS RECOVERY ==========

    function recoverFunds(address payable _recipient, uint256 _amount) external onlyOwner {
        require(_amount <= address(this).balance, "Insufficient contract balance");
        _recipient.transfer(_amount);
        emit FundsRecovered(_recipient, _amount);
    }

    function recoverTokens(address _token, address _recipient, uint256 _amount) external onlyOwner {
        IERC20 token = IERC20(_token);
        require(token.transfer(_recipient, _amount), "Transfer failed");
        emit FundsRecovered(_recipient, _amount);
    }

    // ========== VIEW FUNCTIONS ==========

    function getCampaignSummary(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (
            address creator,
            uint256 goal,
            uint256 raised,
            bool completed,
            bool refundable,
            uint256 minContribution,
            uint256 maxContribution,
            uint256 deadline,
            string memory title,
            string memory description,
            string memory imageHash,
            uint256 category,
            bool isVerified,
            bool hasWithdrawalLimit,
            uint256 withdrawalLimit,
            uint256 totalWithdrawn,
            address tokenAddress,
            uint256 backerCount,
            bool allowPartialWithdrawal,
            uint256 lastWithdrawalTime,
            uint256 withdrawalInterval,
            bool isPromoted
        )
    {
        Campaign storage c = campaigns[_campaignId];
        return (
            c.creator,
            c.goal,
            c.amountRaised,
            c.isCompleted,
            c.isRefundable,
            c.minContribution,
            c.maxContribution,
            c.deadline,
            c.title,
            c.description,
            c.imageHash,
            c.category,
            c.isVerified,
            c.hasWithdrawalLimit,
            c.withdrawalLimit,
            c.totalWithdrawn,
            c.tokenAddress,
            c.backerCount,
            c.allowPartialWithdrawal,
            c.lastWithdrawalTime,
            c.withdrawalInterval,
            promotionEndTime[_campaignId] > block.timestamp
        );
    }

    function getCampaignMetadata(uint256 _campaignId) 
        external 
        view 
        campaignExists(_campaignId) 
        returns (string memory, string memory, string memory) 
    {
        Campaign storage c = campaigns[_campaignId];
        return (c.title, c.description, c.imageHash);
    }

    function getUserCampaigns(address _user) external view returns (uint256[] memory) {
        return userCampaigns[_user];
    }

    function getContributedCampaigns(address _contributor) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](campaignCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (campaigns[i].contributions[_contributor] > 0) {
                result[count] = i;
                count++;
            }
        }
        
        uint256[] memory finalResult = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }

    function getTotalContributions(address _contributor) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= campaignCounter; i++) {
            total += campaigns[i].contributions[_contributor];
        }
        return total;
    }

    function isCampaignActive(uint256 _campaignId) external view campaignExists(_campaignId) returns (bool) {
        Campaign storage c = campaigns[_campaignId];
        return !c.isCompleted && block.timestamp <= c.deadline;
    }

    function getActiveCampaigns() external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](campaignCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (!campaigns[i].isCompleted && block.timestamp <= campaigns[i].deadline) {
                result[count] = i;
                count++;
            }
        }
        
        uint256[] memory finalResult = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }

    function getSuccessfulCampaigns() external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](campaignCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (campaigns[i].isCompleted && campaigns[i].amountRaised >= campaigns[i].goal) {
                result[count] = i;
                count++;
            }
        }
        
        uint256[] memory finalResult = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }

    function getVerifiedCampaigns() external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](campaignCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (campaigns[i].isVerified) {
                result[count] = i;
                count++;
            }
        }
        
        uint256[] memory finalResult = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }

    function getPromotedCampaigns() external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](campaignCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (promotionEndTime[i] > block.timestamp) {
                result[count] = i;
                count++;
            }
        }
        
        uint256[] memory finalResult = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }

    function getCampaignsByCategory(uint256 _category) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](campaignCounter);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (campaigns[i].category == _category) {
                result[count] = i;
                count++;
            }
        }
        
        uint256[] memory finalResult = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }

    function getMilestones(uint256 _campaignId) 
        external 
        view 
        campaignExists(_campaignId) 
        returns (uint256[] memory amounts, string[] memory descriptions, bool[] memory completedStatuses) 
    {
        Campaign storage c = campaigns[_campaignId];
        uint256 count = c.milestones.length;
        
        amounts = new uint256[](count);
        descriptions = new string[](count);
        completedStatuses = new bool[](count);
        
        for (uint256 i = 0; i < count; i++) {
            amounts[i] = c.milestones[i].amount;
            descriptions[i] = c.milestones[i].description;
            completedStatuses[i] = c.milestones[i].isCompleted;
        }
        
        return (amounts, descriptions, completedStatuses);
    }

    function getVerifiedCreators() external view returns (address[] memory) {
        return verifiedCreatorList;
    }

    function isCreatorVerified(address _creator) external view returns (bool) {
        return verifiedCreators[_creator];
    }

    function totalCampaigns() external view returns (uint256) {
        return campaignCounter;
    }

    function isCompleted(uint256 _campaignId) external view campaignExists(_campaignId) returns (bool) {
        return campaigns[_campaignId].isCompleted;
    }

    function fundsRaised(uint256 _campaignId) external view campaignExists(_campaignId) returns (uint256) {
        return campaigns[_campaignId].amountRaised;
    }

    function campaignCreator(uint256 _campaignId) external view campaignExists(_campaignId) returns (address) {
        return campaigns[_campaignId].creator;
    }

    function getContributors(uint256 _campaignId) external view campaignExists(_campaignId) returns (address[] memory) {
        return campaigns[_campaignId].contributors;
    }

    function getMinContribution(uint256 _campaignId) external view campaignExists(_campaignId) returns (uint256) {
        return campaigns[_campaignId].minContribution;
    }

    function getMaxContribution(uint256 _campaignId) external view campaignExists(_campaignId) returns (uint256) {
        return campaigns[_campaignId].maxContribution;
    }

    function getContribution(uint256 _campaignId, address _contributor) external view campaignExists(_campaignId) returns (uint256) {
        return campaigns[_campaignId].contributions[_contributor];
    }

    function timeLeft(uint256 _campaignId) external view campaignExists(_campaignId) returns (uint256) {
        Campaign storage c = campaigns[_campaignId];
        if (block.timestamp >= c.deadline) {
            return 0;
        } else {
            return c.deadline - block.timestamp;
        }
    }

    function getPlatformStats() external view returns (
        uint256 totalFees, 
        uint256 totalCampaignsCreated, 
        uint256 totalVerifiedCreators,
        uint256 totalActiveCampaigns,
        uint256 totalSuccessfulCampaigns
    ) {
        uint256 activeCount = 0;
        uint256 successCount = 0;
        
        for (uint256 i = 1; i <= campaignCounter; i++) {
            if (!campaigns[i].isCompleted && block.timestamp <= campaigns[i].deadline) {
                activeCount++;
            }
            if (campaigns[i].isCompleted && campaigns[i].amountRaised >= campaigns[i].goal) {
                successCount++;
            }
        }
        
        return (
            totalPlatformFeesCollected, 
            campaignCounter, 
            verifiedCreatorList.length,
            activeCount,
            successCount
        );
    }

    // ========== ADMIN FUNCTIONS ==========

    function setPlatformFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee too high"); // Max 10%
        platformFee = _newFee;
        emit PlatformFeeUpdated(_newFee);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function transferCampaignOwnership(uint256 _campaignId, address _newCreator) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        require(_newCreator != address(0), "Invalid address");
        Campaign storage c = campaigns[_campaignId];
        
        uint256[] storage creatorCampaigns = userCampaigns[msg.sender];
        for (uint256 i = 0; i < creatorCampaigns.length; i++) {
            if (creatorCampaigns[i] == _campaignId) {
                creatorCampaigns[i] = creatorCampaigns[creatorCampaigns.length - 1];
                creatorCampaigns.pop();
                break;
            }
        }
        
        userCampaigns[_newCreator].push(_campaignId);
        c.creator = payable(_newCreator);
    }
}
