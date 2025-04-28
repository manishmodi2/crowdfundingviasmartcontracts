// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract CrowdfundingPro is Ownable, Pausable {
    using SafeMath for uint256;

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
    }

    uint256 private campaignCounter;
    mapping(uint256 => Campaign) private campaigns;
    uint256 public platformFee = 250; // Represents 2.5% (250 basis points)
    mapping(address => uint256[]) private userCampaigns;

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

    modifier campaignExists(uint256 _campaignId) {
        require(_campaignId > 0 && _campaignId <= campaignCounter, "Campaign does not exist");
        _;
    }

    modifier onlyCreator(uint256 _campaignId) {
        require(msg.sender == campaigns[_campaignId].creator, "Only campaign creator");
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
        string memory _imageHash
    ) external whenNotPaused {
        require(_goal > 0, "Goal must be greater than zero");
        require(_minContribution > 0, "Minimum contribution must be greater than zero");
        require(_maxContribution >= _minContribution, "Max contribution must be >= min");
        require(_durationInDays > 0, "Duration must be greater than zero");
        require(bytes(_title).length > 0, "Title is required");

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

        userCampaigns[msg.sender].push(campaignCounter);

        emit CampaignCreated(campaignCounter, msg.sender, _goal, c.deadline);
    }

    function contribute(uint256 _campaignId) external payable whenNotPaused campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.value > 0, "Contribution must be greater than zero");
        require(!c.isCompleted, "Campaign has ended");
        require(msg.value >= c.minContribution, "Contribution below minimum");
        require(msg.value <= c.maxContribution, "Contribution exceeds maximum");
        require(block.timestamp <= c.deadline, "Campaign deadline passed");

        if (c.contributions[msg.sender] == 0) {
            c.contributors.push(msg.sender);
        }
        c.contributions[msg.sender] += msg.value;
        c.amountRaised += msg.value;

        emit ContributionReceived(_campaignId, msg.sender, msg.value);

        if (c.amountRaised >= c.goal) {
            c.isCompleted = true;
            uint256 feeAmount = (c.amountRaised * platformFee) / 10000;
            uint256 payout = c.amountRaised - feeAmount;
            c.creator.transfer(payout);
            payable(owner()).transfer(feeAmount);
            emit CampaignSuccessful(_campaignId);
        }
    }

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
        payable(msg.sender).transfer(refundAmount);

        emit RefundIssued(_campaignId, msg.sender, refundAmount);
    }

    function withdrawSurplus(uint256 _campaignId) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(c.isCompleted, "Campaign not completed");

        uint256 excess = c.amountRaised > c.goal ? c.amountRaised - c.goal : 0;
        require(excess > 0, "No excess to withdraw");

        c.amountRaised -= excess;
        c.creator.transfer(excess);

        emit ExcessWithdrawn(_campaignId, excess);
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
                payable(contributor).transfer(contribution);
                emit RefundIssued(_campaignId, contributor, contribution);
            }
        }

        emit CampaignCancelled(_campaignId);
    }

    function extendDeadline(uint256 _campaignId, uint256 _additionalDays) external campaignExists(_campaignId) onlyCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign already completed");

        c.deadline += _additionalDays * 1 days;
        emit DeadlineExtended(_campaignId, c.deadline);
    }

    // ========== NEW FUNCTIONS ==========

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

    function withdrawMilestone(uint256 _campaignId, uint256 _amount) 
        external 
        campaignExists(_campaignId) 
        onlyCreator(_campaignId) 
    {
        Campaign storage c = campaigns[_campaignId];
        require(c.isCompleted, "Campaign not completed");
        require(_amount <= c.amountRaised, "Amount exceeds raised funds");
        
        c.amountRaised = c.amountRaised.sub(_amount);
        uint256 feeAmount = _amount.mul(platformFee).div(10000);
        uint256 payout = _amount.sub(feeAmount);
        
        c.creator.transfer(payout);
        payable(owner()).transfer(feeAmount);
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
            uint256 deadline
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
            c.deadline
        );
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
}
