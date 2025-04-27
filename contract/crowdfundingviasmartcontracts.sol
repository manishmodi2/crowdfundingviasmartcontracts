// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract CrowdfundingPro is Ownable, Pausable {
    struct Campaign {
        address payable creator;
        uint256 goal;
        uint256 amountRaised;
        bool isCompleted;
        bool isRefundable;
        uint256 minContribution;
        uint256 deadline;
        mapping(address => uint256) contributions;
        address[] contributors;
    }

    uint256 private campaignCounter;
    mapping(uint256 => Campaign) private campaigns;
    uint256 public platformFee = 250; // Represents 2.5% (250 basis points)

    event CampaignCreated(uint256 indexed campaignId, address indexed creator, uint256 goal, uint256 deadline);
    event ContributionReceived(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignSuccessful(uint256 indexed campaignId);
    event GoalModified(uint256 indexed campaignId, uint256 newGoal);
    event RefundIssued(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event ExcessWithdrawn(uint256 indexed campaignId, uint256 amount);
    event CampaignCancelled(uint256 indexed campaignId);
    event DeadlineExtended(uint256 indexed campaignId, uint256 newDeadline);
    event PlatformFeeUpdated(uint256 newFee);

    modifier campaignExists(uint256 _campaignId) {
        require(_campaignId > 0 && _campaignId <= campaignCounter, "Campaign does not exist");
        _;
    }

    function createCampaign(uint256 _goal, uint256 _minContribution, uint256 _durationInDays) external whenNotPaused {
        require(_goal > 0, "Goal must be greater than zero");
        require(_minContribution > 0, "Minimum contribution must be greater than zero");
        require(_durationInDays > 0, "Duration must be greater than zero");

        campaignCounter++;
        Campaign storage c = campaigns[campaignCounter];
        c.creator = payable(msg.sender);
        c.goal = _goal;
        c.minContribution = _minContribution;
        c.deadline = block.timestamp + (_durationInDays * 1 days);

        emit CampaignCreated(campaignCounter, msg.sender, _goal, c.deadline);
    }

    function contribute(uint256 _campaignId) external payable whenNotPaused campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.value > 0, "Contribution must be greater than zero");
        require(!c.isCompleted, "Campaign has ended");
        require(msg.value >= c.minContribution, "Contribution below minimum");
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

    function modifyGoal(uint256 _campaignId, uint256 _newGoal) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Unauthorized");
        require(!c.isCompleted, "Cannot modify completed campaign");
        require(_newGoal > c.amountRaised, "Goal must exceed amount raised");

        c.goal = _newGoal;
        emit GoalModified(_campaignId, _newGoal);
    }

    function enableRefunds(uint256 _campaignId) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Only creator can enable refunds");
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

    function withdrawSurplus(uint256 _campaignId) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Only creator can withdraw");
        require(c.isCompleted, "Campaign not completed");

        uint256 excess = c.amountRaised > c.goal ? c.amountRaised - c.goal : 0;
        require(excess > 0, "No excess to withdraw");

        c.amountRaised -= excess;
        c.creator.transfer(excess);

        emit ExcessWithdrawn(_campaignId, excess);
    }

    function cancelCampaign(uint256 _campaignId) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Only creator can cancel the campaign");
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

    function extendDeadline(uint256 _campaignId, uint256 _additionalDays) external campaignExists(_campaignId) {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Only creator can extend");
        require(!c.isCompleted, "Campaign already completed");

        c.deadline += _additionalDays * 1 days;

        emit DeadlineExtended(_campaignId, c.deadline);
    }

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
            uint256 deadline
        )
    {
        Campaign storage c = campaigns[_campaignId];
        return (c.creator, c.goal, c.amountRaised, c.isCompleted, c.isRefundable, c.minContribution, c.deadline);
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

