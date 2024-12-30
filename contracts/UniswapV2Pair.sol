pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3; // Minimum liquidity to prevent division by zero
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)'))); // Selector for ERC20 transfer

    address public factory; // Address of the factory contract
    address public token0; // Address of the first token in the pair
    address public token1; // Address of the second token in the pair

    uint112 private reserve0; // Reserve of token0
    uint112 private reserve1; // Reserve of token1
    uint32  private blockTimestampLast; // Last block timestamp

    uint public price0CumulativeLast; // Cumulative price of token0
    uint public price1CumulativeLast; // Cumulative price of token1
    uint public kLast; // Last product of reserves

    uint private unlocked = 1; // Reentrancy guard
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED'); // Ensure contract is not locked
        unlocked = 0; // Lock the contract
        _;
        unlocked = 1; // Unlock the contract
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0; // Return reserve0
        _reserve1 = reserve1; // Return reserve1
        _blockTimestampLast = blockTimestampLast; // Return last block timestamp
    }

    function _safeTransfer(address token, address to, uint value) private {
        // Call the transfer function of the ERC20 token
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // Ensure the transfer was successful
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender; // Set the factory to the deployer
    }

    // Initialize the pair with two tokens
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // Ensure caller is factory
        token0 = _token0; // Set token0
        token1 = _token1; // Set token1
    }

    // Update reserves and price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW'); // Prevent overflow
        uint32 blockTimestamp = uint32(block.timestamp % 2**32); // Current timestamp modulo 2^32
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // Time since last update
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // Update price accumulators if time has elapsed and reserves are non-zero
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed; // Update price0
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed; // Update price1
        }
        reserve0 = uint112(balance0); // Update reserve0
        reserve1 = uint112(balance1); // Update reserve1
        blockTimestampLast = blockTimestamp; // Update last timestamp
        emit Sync(reserve0, reserve1); // Emit Sync event
    }

    // Mint liquidity tokens when fees are on
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo(); // Get fee recipient
        feeOn = feeTo != address(0); // Check if fees are enabled
        uint _kLast = kLast; // Last k value for gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1)); // Calculate sqrt(k)
                uint rootKLast = Math.sqrt(_kLast); // Calculate sqrt(kLast)
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast)); // Numerator for liquidity
                    uint denominator = rootK.mul(5).add(rootKLast); // Denominator for liquidity
                    uint liquidity = numerator / denominator; // Calculate liquidity to mint
                    if (liquidity > 0) _mint(feeTo, liquidity); // Mint liquidity to fee recipient
                }
            }
        } else if (_kLast != 0) {
            kLast = 0; // Reset kLast if fees are off
        }
    }

    // Mint new liquidity tokens
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // Get current reserves
        uint balance0 = IERC20(token0).balanceOf(address(this)); // Current balance of token0
        uint balance1 = IERC20(token1).balanceOf(address(this)); // Current balance of token1
        uint amount0 = balance0.sub(_reserve0); // Amount of token0 added
        uint amount1 = balance1.sub(_reserve1); // Amount of token1 added

        bool feeOn = _mintFee(_reserve0, _reserve1); // Handle fee minting
        uint _totalSupply = totalSupply; // Current total supply
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY); // Initial liquidity
            _mint(address(0), MINIMUM_LIQUIDITY); // Lock minimum liquidity
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1); // Calculate liquidity
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED'); // Ensure liquidity is positive
        _mint(to, liquidity); // Mint liquidity to user

        _update(balance0, balance1, _reserve0, _reserve1); // Update reserves
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // Update kLast if fee is on
        emit Mint(msg.sender, amount0, amount1); // Emit Mint event
    }

    // Burn liquidity tokens and retrieve underlying assets
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // Get current reserves
        address _token0 = token0; // Address of token0
        address _token1 = token1; // Address of token1
        uint balance0 = IERC20(_token0).balanceOf(address(this)); // Current balance of token0
        uint balance1 = IERC20(_token1).balanceOf(address(this)); // Current balance of token1
        uint liquidity = balanceOf[address(this)]; // Liquidity to burn

        bool feeOn = _mintFee(_reserve0, _reserve1); // Handle fee minting
        uint _totalSupply = totalSupply; // Current total supply
        amount0 = liquidity.mul(balance0) / _totalSupply; // Calculate amount0 to return
        amount1 = liquidity.mul(balance1) / _totalSupply; // Calculate amount1 to return
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED'); // Ensure amounts are positive
        _burn(address(this), liquidity); // Burn liquidity
        _safeTransfer(_token0, to, amount0); // Transfer token0 to user
        _safeTransfer(_token1, to, amount1); // Transfer token1 to user
        balance0 = IERC20(_token0).balanceOf(address(this)); // Update balance0
        balance1 = IERC20(_token1).balanceOf(address(this)); // Update balance1

        _update(balance0, balance1, _reserve0, _reserve1); // Update reserves
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // Update kLast if fee is on
        emit Burn(msg.sender, amount0, amount1, to); // Emit Burn event
    }

    // Swap tokens
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT'); // Ensure output amounts are positive
            // @note : why can't we do ierc(token1).balanceOf(address(this)) instead of getReserves()?

            // as tokens can be sent directly as well, which will break our invariant k 
            (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // Get current reserves 

        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY'); // Ensure sufficient liquidity
        uint balance0;
        uint balance1;
        {  // avoids stack too deep errors - reason for using this block, 
            address _token0 = token0; // Address of token0
            address _token1 = token1; // Address of token1
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO'); // Prevent sending to token addresses
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // Transfer token0 out
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // Transfer token1 out
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data); // Callback for flash swaps


            balance0 = IERC20(_token0).balanceOf(address(this)); // Update balance0
            balance1 = IERC20(_token1).balanceOf(address(this)); // Update balance1
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0; // Calculate amount0 in
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0; // Calculate amount1 in
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT'); // Ensure input amounts are positive
        { 
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3)); // Adjusted balance0 for fee
            // Example:
            // Suppose balance0 = 1000 tokens, amount0In = 100 tokens
            // balance0Adjusted = 1000 * 1000 - 100 * 3 = 1000000 - 300 = 999700
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3)); // Adjusted balance1 for fee
            // Example:
            // Suppose balance1 = 2000 tokens, amount1In = 200 tokens
            // balance1Adjusted = 2000 * 1000 - 200 * 3 = 2000000 - 600 = 1999400
            require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K'); // Ensure invariant is maintained
            // Explanation:
            // The product of the adjusted balances must be at least equal to the product of the reserves multiplied by 1000^2
            // This ensures that the constant product invariant k is maintained after accounting for fees
            // For example:
            // If _reserve0 = 1000 and _reserve1 = 2000, then _reserve0 * _reserve1 = 2,000,000
            // balance0Adjusted * balance1Adjusted should be >= 2,000,000 * 1,000,000 = 2,000,000,000,000
        }

        _update(balance0, balance1, _reserve0, _reserve1); // Update reserves
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to); // Emit Swap event
    }

    // Force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // Address of token0
        address _token1 = token1; // Address of token1
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0)); // Transfer excess token0
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1)); // Transfer excess token1
    }

    // Force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1); // Sync reserves with balances
    }
}

