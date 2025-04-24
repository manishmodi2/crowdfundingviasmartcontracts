// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Crowdfunding {
    struct Campaign {
        address payable creator;
        uint256 goal;
        uint256 amountRaised;
        bool isCompleted;
    }

    mapping(uint256 => Campaign) public campaigns;
    uint256 public campaignCount;

    event CampaignCreated(uint256 campaignId, address creator, uint256 goal);
    event Funded(uint256 campaignId, address funder, uint256 amount);
    event CampaignCompleted(uint256 campaignId);
    event GoalUpdated(uint256 campaignId, uint256 newGoal);

    function createCampaign(uint256 _goal) public {
        campaignCount++;
        campaigns[campaignCount] = Campaign({
            creator: payable(msg.sender),
            goal: _goal,
            amountRaised: 0,
            isCompleted: false
        });
        emit CampaignCreated(campaignCount, msg.sender, _goal);
    }

    function fundCampaign(uint256 _campaignId) public payable {
        Campaign storage campaign = campaigns[_campaignId];
        require(!campaign.isCompleted, "Campaign is already completed");
        require(msg.value > 0, "Funding amount must be greater than 0");

        campaign.amountRaised += msg.value;
        emit Funded(_campaignId, msg.sender, msg.value);

        if (campaign.amountRaised >= campaign.goal) {
            campaign.isCompleted = true;
            campaign.creator.transfer(campaign.amountRaised);
            emit CampaignCompleted(_campaignId);
        }
    }

    function updateGoal(uint256 _campaignId, uint256 _newGoal) public {
        Campaign storage campaign = campaigns[_campaignId];
        require(msg.sender == campaign.creator, "Only the creator can update the goal");
        require(!campaign.isCompleted, "Cannot update goal of a completed campaign");
        require(_newGoal > campaign.amountRaised, "New goal must be greater than the amount raised");

        campaign.goal = _newGoal;
        emit GoalUpdated(_campaignId, _newGoal);
    }

    function getCampaignCount() public view returns (uint256) {
        return campaignCount;
    }

    function isCampaignCompleted(uint256 _campaignId) public view returns (bool) {
        return campaigns[_campaignId].isCompleted;
    }

    function getAmountRaised(uint256 _campaignId) public view returns (uint256) {
        return campaigns[_campaignId].amountRaised;
    }

    function getCreator(uint256 _campaignId) public view returns (address) {
        return campaigns[_campaignId].creator;
    }
}
