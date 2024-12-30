/**
 * @title Uniswap V2 Factory Contract
 * @notice Creates and manages Uniswap V2 pairs for token swapping
 * @dev This contract is responsible for deploying new pairs and managing fees
 *
 * State Variables:
 * @dev feeTo - Address that receives protocol fees (if enabled)
 * @dev feeToSetter - Address with permission to change feeTo address
 * @dev getPair - Mapping of token addresses to their corresponding pair contract
 * @dev allPairs - Array containing addresses of all created pairs
 *
 * Events:
 * @dev PairCreated - Emitted when a new pair is created
 * @param token0 First token address (sorted)
 * @param token1 Second token address (sorted)
 * @param pair Address of the created pair contract
 * @param length Total number of pairs after creation
 *
 * Functions:
 * @notice constructor(address _feeToSetter)
 * Initializes the factory with address that can set fee recipient
 *
 * @notice allPairsLength()
 * Returns total number of pairs created through the factory
 *
 * @notice createPair(address tokenA, address tokenB)
 * Creates a new pair for two tokens if it doesn't exist
 * Implementation:
 * 1. Validates token addresses are different and non-zero
 * 2. Sorts token addresses (lower address becomes token0)
 * 3. Ensures pair doesn't already exist
 * 4. Deploys new pair contract using CREATE2
 *    - Uses keccak256(token0, token1) as salt for deterministic addresses
 *    - CREATE2 formula: keccak256(0xFF, deployer, salt, bytecode)
 * 5. Initializes pair with sorted tokens
 * 6. Records pair in mappings and array
 * 7. Emits PairCreated event
 *
 * @notice setFeeTo(address _feeTo)
 * Sets address to receive protocol fees
 * @dev Only callable by feeToSetter
 *
 * @notice setFeeToSetter(address _feeToSetter)
 * Updates address with permission to change feeTo
 * @dev Only callable by current feeToSetter
 *
 * Math/Logic Notes:
 * - Pair addresses are deterministic through CREATE2
 * - Protocol fee is 1/6th of LP fee (0.05% of swap)
 * - Total LP fee is 0.3% per swap
 * - Two-way mapping ensures pairs can be found using tokens in any order
 * - Salt generation ensures unique pair addresses
 */
pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // Ensure the two tokens are not identical
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        
        // Sort tokens to maintain consistent ordering

        // address can be 20 bytes hexadecimals -> 160 bits number this can be compared directly    

        // so that, the pool is created with the same order of tokens 
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        // Ensure the first token is not the zero address
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        
        // Check if the pair already exists
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        
        // Get the bytecode of the UniswapV2Pair contract,
        // the creation code is the bytecode executed by the Ethereum Virtual Machine (EVM) during the deployment of a contract. This code includes the constructor logic and any initialization instructions necessary to set up the contract's initial state. Once executed, the creation code produces the contract's runtime bytecode

        
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        
        // Create a unique salt using the token addresses
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));


        // How is create2 used to deploy a contract with a deterministic address?
        // keccak256(0xFF ++ sender_address ++ salt ++ keccak256(bytecode))[12:]
        // Deploy the pair contract using CREATE2 for deterministic address
            // @note
        // there are no constructor arguments for the UniswapV2Pair contract, so the bytecode is the same for all pairs
        assembly {
            pair := create2(
                0, // the amount of ether to transfer to the new contract
                 add(bytecode, 32) //  the memory location from where the bytecode will be copied 
                 , mload(bytecode), // the length of the bytecode
                  salt //  A 32-byte value used to ensure the uniqueness of the contract's address
                  )
        }
        
        // Initialize the newly created pair with the sorted tokens
        IUniswapV2Pair(pair).initialize(token0, token1);
        
        // Record the pair in the mapping for both token orders
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        
        // Add the new pair to the list of all pairs
        allPairs.push(pair);
        
        // Emit an event indicating a new pair has been created
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
