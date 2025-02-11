// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./lib/SafeMath8.sol";
import "./owner/Operator.sol";
import "./interfaces/IOracle.sol";

contract SNAKE is ERC20Burnable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    uint256 public constant INITIAL_DAOFUND_DISTRIBUTION = 1000 ether; // 1000 SNAKE
    uint256 public constant GENESIS_DISTRIBUTION = 469000 ether; // 450k SNAKE

    bool public rewardsDistributed = false;


    // Address of the Oracle
    address public snakeOracle;

    /**
     * @notice Constructs the SNAKE ERC-20 contract.
     */
    constructor() ERC20("SNAKE", "SNAKE") {
        // Mints 200 SNAKE to contract creator for initial pool setup

        _mint(msg.sender, 200 ether);
    }

    function _getSnakePrice() internal view returns (uint256 _snakePrice) {
        try IOracle(snakeOracle).consult(address(this), 1e18) returns (uint256 _price) {
            return uint256(_price);
        } catch {
            revert("Snake: failed to fetch SNAKE price from Oracle");
        }
    }

    function setSnakeOracle(address _snakeOracle) public onlyOperator {
        require(_snakeOracle != address(0), "oracle address cannot be 0 address");
        snakeOracle = _snakeOracle;
    }

    /**
     * @notice Operator mints SNAKE to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of SNAKE to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _daoFund,
        address _genesis
    ) external onlyOperator {
        require(_daoFund != address(0), "!_treasury");
        require(_genesis != address(0), "!_genesis");
        require(!rewardsDistributed, "only can distribute once");
        rewardsDistributed = true;
        _mint(_daoFund, INITIAL_DAOFUND_DISTRIBUTION);
        _mint(_genesis, GENESIS_DISTRIBUTION);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}