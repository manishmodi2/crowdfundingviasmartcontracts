// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Crowdfunding {
    struct Campaign {
        address payable creator;
        uint256 goal;
        uint256 amountRaised;
        bool isCompleted;
        bool isRefundable;
        mapping(address => uint256) contributions;
    }

    uint256 private campaignCounter;
    mapping(uint256 => Campaign) private campaigns;

    event CampaignCreated(uint256 indexed campaignId, address indexed creator, uint256 goal);
    event ContributionReceived(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignSuccessful(uint256 indexed campaignId);
    event GoalModified(uint256 indexed campaignId, uint256 newGoal);
    event RefundIssued(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event ExcessWithdrawn(uint256 indexed campaignId, uint256 amount);

    /// @notice Creates a new crowdfunding campaign
    /// @param _goal The fundraising goal in wei
    function createCampaign(uint256 _goal) external {
        require(_goal > 0, "Goal must be greater than zero");

        campaignCounter++;
        Campaign storage c = campaigns[campaignCounter];
        c.creator = payable(msg.sender);
        c.goal = _goal;

        emit CampaignCreated(campaignCounter, msg.sender, _goal);
    }

    /// @notice Contribute to a specific campaign
    function contribute(uint256 _campaignId) external payable {
        require(msg.value > 0, "Contribution must be greater than zero");
        Campaign storage c = campaigns[_campaignId];
        require(!c.isCompleted, "Campaign has ended");

        c.amountRaised += msg.value;
        c.contributions[msg.sender] += msg.value;

        emit ContributionReceived(_campaignId, msg.sender, msg.value);

        if (c.amountRaised >= c.goal) {
            c.isCompleted = true;
            c.creator.transfer(c.amountRaised);
            emit CampaignSuccessful(_campaignId);
        }
    }

    /// @notice Update the fundraising goal of a campaign
    function modifyGoal(uint256 _campaignId, uint256 _newGoal) external {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Unauthorized");
        require(!c.isCompleted, "Cannot modify completed campaign");
        require(_newGoal > c.amountRaised, "Goal must exceed amount raised");

        c.goal = _newGoal;
        emit GoalModified(_campaignId, _newGoal);
    }

    /// @notice View the amount contributed by a specific address to a campaign
    function getContribution(uint256 _campaignId, address _contributor) external view returns (uint256) {
        return campaigns[_campaignId].contributions[_contributor];
    }

    /// @notice Enable refunds for an unfinished campaign
    function enableRefunds(uint256 _campaignId) external {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Only creator can enable refunds");
        require(!c.isCompleted, "Completed campaign");

        c.isRefundable = true;
    }

    /// @notice Request a refund if a campaign is refundable and not completed
    function requestRefund(uint256 _campaignId) external {
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

    /// @notice Allow the creator to withdraw any extra funds raised beyond the goal
    function withdrawSurplus(uint256 _campaignId) external {
        Campaign storage c = campaigns[_campaignId];
        require(msg.sender == c.creator, "Only creator can withdraw");
        require(c.isCompleted, "Campaign not completed");

        uint256 excess = c.amountRaised > c.goal ? c.amountRaised - c.goal : 0;
        require(excess > 0, "No excess to withdraw");

        c.amountRaised -= excess;
        c.creator.transfer(excess);

        emit ExcessWithdrawn(_campaignId, excess);
    }

    // ---------- View Helper Functions ----------

    function getCampaignSummary(uint256 _campaignId)
        external
        view
        returns (
            address creator,
            uint256 goal,
            uint256 raised,
            bool completed,
            bool refundable
        )
    {
        Campaign storage c = campaigns[_campaignId];
        return (c.creator, c.goal, c.amountRaised, c.isCompleted, c.isRefundable);
    }

    function totalCampaigns() external view returns (uint256) {
        return campaignCounter;
    }

    function isCompleted(uint256 _campaignId) external view returns (bool) {
        return campaigns[_campaignId].isCompleted;
    }

    function fundsRaised(uint256 _campaignId) external view returns (uint256) {
        return campaigns[_campaignId].amountRaised;
    }

    function campaignCreator(uint256 _campaignId) external view returns (address) {
        return campaigns[_campaignId].creator;
    }
}
