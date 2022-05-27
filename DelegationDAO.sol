// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "./StakingInterface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract DelegationDAO is AccessControl {
    using SafeMath for uint256;

    bytes32 public constant MEMBER = keccak256("MEMBER");

    enum daoState {COLLECTING, STAKING, REVOKING, REVOKED}

    daoState public currentState;

    //Keep track of member stakes - does not include staking rewards.
    mapping(address => uint256) public memberStakes;

    //Total amount of pool stake - not including rewards.
    uint256 public totalStake;

    //Parachain Staking wrapper at the known precompile address.
    //This will be used to make calls to the underlying staking mechanism.
    ParachainStaking public staking;
    
    //Moonbase Alpha Precompile Address.
    address public constant stakingPrecompileAddress = 0x0000000000000000000000000000000000000800;

    //Minimum delegation amount.
    uint256 public constant MinDelegatorStk = 5 ether;

    //The collator we want to delegate to.
    address public target;

    //Event for member deposit.
    event deposit(address indexed _from, uint _value);

    //Event for a member withdrawal.
    event withdrawal(address indexed _from, address indexed _to, uint _value);

    //Initialize a new DelegatioDAO dedicated to delegating to the given collator target.
    constructor(address _target, address admin){
        target = _target;

        staking = ParachainStaking(stakingPrecompileAddress);

        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(MEMBER, admin);

        currentState = daoState.COLLECTING;
    }
    //Grants user the role of admin.
    function grant_admin(address newAdmin) public
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyRole(MEMBER)
        {
            grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            grantRole(MEMBER, newAdmin);
        }
    
    //Grants a user membership.
    function grant_member(address newMember) public
        onlyRole(DEFAULT_ADMIN_ROLE)
        {
            grantRole(MEMBER, newMember);
        }
    
    //Revoke a user membership.
    function remove_member(address payable exMember) public
        onlyRole(DEFAULT_ADMIN_ROLE)
        {
            revokeRole(MEMBER, exMember);
        }
    
    //Check how much free balance the DAO currently has. It should be staking rewards
    //if the DAO is currently in Staking or Revoking State.
    function check_free_balance() public view onlyRole(MEMBER) returns(uint256){
        return address(this).balance;
    }

    //Change the collator target, admin only.
    function change_target(address newCollator) public onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(currentState == daoState.REVOKED || currentState == daoState.COLLECTING,
        "The DAO is not in the correct state to change the staking target.");
        target = newCollator;
    }

    function reset_dao() public onlyRole(DEFAULT_ADMIN_ROLE){
        currentState = daoState.COLLECTING;
    }

    function add_stake() external payable onlyRole(MEMBER){
        if (currentState == daoState.STAKING){
            //Sanity check.
            if (!staking.is_delegator(address(this))){
                revert("The DAO is in an inconsistent State");
            }
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            staking.delegator_bond_more(target, msg.value);
        }
        else if(currentState == daoState.COLLECTING){
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            if(totalStake < MinDelegatorStk){
                return;
            }
            else{
                staking.delegate(target, address(this).balance, staking.candidate_delegation_count(target), staking.delegator_delegation_count(address(this)));
            }
        }
        else {
            revert("The DAO is not accepting new stakes in  its current state.");
        }
    }

    function schedule_revoke() public onlyRole(DEFAULT_ADMIN_ROLE){
        require(currentState == daoState.STAKING, "The DAO is not in the correct state to schedule a revoke");
        staking.schedule_revoke_delegation(target);
        currentState = daoState.REVOKING;
    }

    function execute_revoke() internal onlyRole(MEMBER) returns(bool){
        require(currentState == daoState.REVOKING, "The DAO is not in the correct state to execute a revoke");
        staking.execute_delegation_request(address(this), target);
        if(staking.is_delegator(address(this))){
            return false;
        } else {
            currentState = daoState.REVOKED;
            return true;
        }  
    }

    function withdraw(address payable account)public onlyRole(MEMBER){
        require(currentState != daoState.STAKING, "The DAO in not in the correct state to withdraw.");

        if(currentState == daoState.REVOKING){
            bool result = execute_revoke();
            require(result, "Exit delay period has not finished yet.");
        }

        if(currentState == daoState.REVOKED || currentState == daoState.COLLECTING){
            //Sanity checks.
            if(staking.is_delegator(address(this))){
                revert("The DAO is in an inconsistent state.");
            }
            require(totalStake!=0, "Cannot divide by zero.");

            //Calculate the amount that the member is owed.
            uint amount =address(this).balance.mul(memberStakes[msg.sender]).div(totalStake);
            require(check_free_balance() >= amount, "Not enough free balance for withdrawal.");
            Address.sendValue(account, amount);
            totalStake =totalStake.sub(memberStakes[msg.sender]);
            memberStakes[msg.sender] = 0;
            emit withdrawal(msg.sender, account, amount);
        }
    }
}
