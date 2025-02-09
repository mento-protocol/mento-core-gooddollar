// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IBancorExchangeProvider} from "contracts/interfaces/IBancorExchangeProvider.sol";
import {IExchangeProvider} from "contracts/interfaces/IExchangeProvider.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IReserve} from "contracts/interfaces/IReserve.sol";

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {BancorFormula} from "contracts/BancorFormula.sol";
import {UD60x18, unwrap, wrap} from "prb/math/UD60x18.sol";

/**
 * @title BancorExchangeProvider
 * @notice Provides exchange functionality for Bancor pools.
 */
contract BancorExchangeProvider is
    IExchangeProvider,
    IBancorExchangeProvider,
    BancorFormula,
    OwnableUpgradeable
{
    /* ==================== State Variables ==================== */

    // Address of the broker contract.
    address public broker;

    // Address of the reserve contract.
    IReserve public reserve;

    // Maps an exchange id to the corresponding PoolExchange struct.
    // exchangeId is in the format "asset0Symbol:asset1Symbol"
    mapping(bytes32 => PoolExchange) public exchanges;
    bytes32[] public exchangeIds;

    // Token precision multiplier used to normalize values to the
    // same precision when calculating amounts.
    mapping(address => uint256) public tokenPrecisionMultipliers;

    /* ==================== Constructor ==================== */

    /**
     * @dev Should be called with disable=true in deployments when
     * it's accessed through a Proxy.
     * Call this with disable=false during testing, when used
     * without a proxy.
     * @param disable Set to true to run `_disableInitializers()` inherited from
     * openzeppelin-contracts-upgradeable/Initializable.sol
     */
    constructor(bool disable) {
        if (disable) {
            _disableInitializers();
        }
    }

    /**
     * @notice Allows the contract to be upgradable via the proxy.
     * @param _broker The address of the broker contract.
     * @param _reserve The address of the reserve contract.
     */
    function initialize(address _broker, address _reserve) public initializer {
        _initialize(_broker, _reserve);
    }

    function _initialize(
        address _broker,
        address _reserve
    ) internal onlyInitializing {
        __Ownable_init();

        BancorFormula.init();
        setBroker(_broker);
        setReserve(_reserve);
    }

    /* ==================== Modifiers ==================== */

    modifier onlyBroker() {
        require(msg.sender == broker, "Caller is not the Broker");
        _;
    }

    modifier verifyExchangeTokens(
        address tokenIn,
        address tokenOut,
        PoolExchange memory exchange
    ) {
        require(
            (tokenIn == exchange.reserveAsset &&
                tokenOut == exchange.tokenAddress) ||
                (tokenIn == exchange.tokenAddress &&
                    tokenOut == exchange.reserveAsset),
            "tokenIn and tokenOut must match exchange"
        );
        _;
    }

    /* ==================== View Functions ==================== */

    /**
     * @notice Get a PoolExchange from storage.
     * @param exchangeId the exchange id
     */
    function getPoolExchange(
        bytes32 exchangeId
    ) public view returns (PoolExchange memory exchange) {
        exchange = exchanges[exchangeId];
        require(
            exchange.tokenAddress != address(0),
            "An exchange with the specified id does not exist"
        );
        return exchange;
    }

    /**
     * @notice Get all exchange IDs.
     * @return exchangeIds List of the exchangeIds.
     */
    function getExchangeIds() external view returns (bytes32[] memory) {
        return exchangeIds;
    }

    /**
     * @notice Get all exchanges (used by interfaces)
     * @dev We don't expect the number of exchanges to grow to
     * astronomical values so this is safe gas-wise as is.
     */
    function getExchanges() public view returns (Exchange[] memory _exchanges) {
        uint256 numExchanges = exchangeIds.length;
        _exchanges = new Exchange[](numExchanges);
        for (uint256 i = 0; i < numExchanges; i++) {
            _exchanges[i].exchangeId = exchangeIds[i];
            _exchanges[i].assets = new address[](2);
            _exchanges[i].assets[0] = exchanges[exchangeIds[i]].reserveAsset;
            _exchanges[i].assets[1] = exchanges[exchangeIds[i]].tokenAddress;
        }
    }

    /**
     * @notice Calculate amountOut of tokenOut received for a given amountIn of tokenIn
     * @param exchangeId The id of the exchange i.e PoolExchange to use
     * @param tokenIn The token to be sold
     * @param tokenOut The token to be bought
     * @param amountIn The amount of tokenIn to be sold
     * @return amountOut The amount of tokenOut to be bought
     */
    function getAmountOut(
        bytes32 exchangeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view virtual returns (uint256 amountOut) {
        PoolExchange memory exchange = getPoolExchange(exchangeId);
        uint256 scaledAmountIn = amountIn * tokenPrecisionMultipliers[tokenIn];
        uint256 scaledAmountOut = _getAmountOut(
            exchange,
            tokenIn,
            tokenOut,
            scaledAmountIn
        );
        amountOut = scaledAmountOut / tokenPrecisionMultipliers[tokenOut];
        return amountOut;
    }

    /**
     * @notice Calculate amountIn of tokenIn for a given amountOut of tokenOut
     * @param exchangeId The id of the exchange i.e PoolExchange to use
     * @param tokenIn The token to be sold
     * @param tokenOut The token to be bought
     * @param amountOut The amount of tokenOut to be bought
     * @return amountIn The amount of tokenIn to be sold
     */
    function getAmountIn(
        bytes32 exchangeId,
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) external view virtual returns (uint256 amountIn) {
        PoolExchange memory exchange = getPoolExchange(exchangeId);
        uint256 scaledAmountOut = amountOut *
            tokenPrecisionMultipliers[tokenOut];
        uint256 scaledAmountIn = _getAmountIn(
            exchange,
            tokenIn,
            tokenOut,
            scaledAmountOut
        );
        amountIn = scaledAmountIn / tokenPrecisionMultipliers[tokenIn];
        return amountIn;
    }

    /**
     * @notice Get the current price of the pool.
     * @param exchangeId The id of the pool to get the price for.
     * @return price The current continous price of the pool.
     */
    function currentPrice(
        bytes32 exchangeId
    ) public view returns (uint256 price) {
        // calculates: reserveBalance / (tokenSupply * reserveRatio)
        require(
            exchanges[exchangeId].reserveAsset != address(0),
            "Exchange does not exist"
        );
        PoolExchange memory exchange = getPoolExchange(exchangeId);
        uint256 scaledReserveRatio = uint256(exchange.reserveRatio) * 1e10;
        UD60x18 denominator = wrap(exchange.tokenSupply).mul(
            wrap(scaledReserveRatio)
        );
        price = unwrap(wrap(exchange.reserveBalance).div(denominator));
        return price;
    }

    /* ==================== Mutative Functions ==================== */

    /**
     * @notice Sets the address of the broker contract.
     * @param _broker The new address of the broker contract.
     */
    function setBroker(address _broker) public onlyOwner {
        require(_broker != address(0), "Broker address must be set");
        broker = _broker;
        emit BrokerUpdated(_broker);
    }

    /**
     * @notice Sets the address of the reserve contract.
     * @param _reserve The new address of the reserve contract.
     */
    function setReserve(address _reserve) public onlyOwner {
        require(address(_reserve) != address(0), "Reserve address must be set");
        reserve = IReserve(_reserve);
        emit ReserveUpdated(address(_reserve));
    }

    /**
     * @notice Sets the exit contribution for a pool.
     * @param exchangeId The id of the pool.
     * @param exitContribution The exit contribution.
     */
    function setExitContribution(
        bytes32 exchangeId,
        uint32 exitContribution
    ) external onlyOwner {
        require(
            exchanges[exchangeId].reserveAsset != address(0),
            "Exchange does not exist"
        );
        require(exitContribution <= MAX_WEIGHT, "Invalid exit contribution");

        PoolExchange storage exchange = exchanges[exchangeId];
        exchange.exitContribution = exitContribution;
        emit ExitContributionSet(exchangeId, exitContribution);
    }

    /**
     * @notice Creates a new exchange using the given parameters.
     * @param _exchange the PoolExchange to create.
     * @return exchangeId The id of the newly created exchange.
     */
    function createExchange(
        PoolExchange calldata _exchange
    ) external onlyOwner returns (bytes32 exchangeId) {
        PoolExchange memory exchange = _exchange;
        validate(exchange);

        exchangeId = keccak256(
            abi.encodePacked(
                IERC20(exchange.reserveAsset).symbol(),
                IERC20(exchange.tokenAddress).symbol()
            )
        );
        require(
            exchanges[exchangeId].reserveAsset == address(0),
            "Exchange already exists"
        );

        uint256 reserveAssetDecimals = IERC20(exchange.reserveAsset).decimals();
        uint256 tokenDecimals = IERC20(exchange.tokenAddress).decimals();
        require(
            reserveAssetDecimals <= 18,
            "reserve token decimals must be <= 18"
        );
        require(tokenDecimals <= 18, "token decimals must be <= 18");

        tokenPrecisionMultipliers[exchange.reserveAsset] =
            10 ** (18 - uint256(reserveAssetDecimals));
        tokenPrecisionMultipliers[exchange.tokenAddress] =
            10 ** (18 - uint256(tokenDecimals));

        exchanges[exchangeId] = exchange;
        exchangeIds.push(exchangeId);
        emit ExchangeCreated(
            exchangeId,
            exchange.reserveAsset,
            exchange.tokenAddress
        );
    }

    /**
     * @notice Destroys a exchange with the given parameters if it exists.
     * @param exchangeId the id of the exchange to destroy
     * @param exchangeIdIndex The index of the exchangeId in the ids array
     * @return destroyed A boolean indicating whether or not the exchange was successfully destroyed.
     */
    function destroyExchange(
        bytes32 exchangeId,
        uint256 exchangeIdIndex
    ) external onlyOwner returns (bool destroyed) {
        require(
            exchangeIdIndex < exchangeIds.length,
            "exchangeIdIndex not in range"
        );
        require(
            exchangeIds[exchangeIdIndex] == exchangeId,
            "exchangeId at index doesn't match"
        );
        PoolExchange memory exchange = exchanges[exchangeId];

        delete exchanges[exchangeId];
        exchangeIds[exchangeIdIndex] = exchangeIds[exchangeIds.length - 1];
        exchangeIds.pop();
        destroyed = true;

        emit ExchangeDestroyed(
            exchangeId,
            exchange.reserveAsset,
            exchange.tokenAddress
        );
    }

    /**
     * @notice Execute a token swap with fixed amountIn
     * @param exchangeId The id of exchange, i.e. PoolExchange to use
     * @param tokenIn The token to be sold
     * @param tokenOut The token to be bought
     * @param amountIn The amount of tokenIn to be sold
     * @return amountOut The amount of tokenOut to be bought
     */
    function swapIn(
        bytes32 exchangeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public virtual onlyBroker returns (uint256 amountOut) {
        PoolExchange memory exchange = getPoolExchange(exchangeId);
        uint256 scaledAmountIn = amountIn * tokenPrecisionMultipliers[tokenIn];
        uint256 scaledAmountOut = _getAmountOut(
            exchange,
            tokenIn,
            tokenOut,
            scaledAmountIn
        );
        executeSwap(exchangeId, tokenIn, scaledAmountIn, scaledAmountOut);

        amountOut = scaledAmountOut / tokenPrecisionMultipliers[tokenOut];
        return amountOut;
    }

    /**
     * @notice Execute a token swap with fixed amountOut
     * @param exchangeId The id of exchange, i.e. PoolExchange to use
     * @param tokenIn The token to be sold
     * @param tokenOut The token to be bought
     * @param amountOut The amount of tokenOut to be bought
     * @return amountIn The amount of tokenIn to be sold
     */
    function swapOut(
        bytes32 exchangeId,
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) public virtual onlyBroker returns (uint256 amountIn) {
        PoolExchange memory exchange = getPoolExchange(exchangeId);
        uint256 scaledAmountOut = amountOut *
            tokenPrecisionMultipliers[tokenOut];
        uint256 scaledAmountIn = _getAmountIn(
            exchange,
            tokenIn,
            tokenOut,
            scaledAmountOut
        );
        executeSwap(exchangeId, tokenIn, scaledAmountIn, scaledAmountOut);

        amountIn = scaledAmountIn / tokenPrecisionMultipliers[tokenIn];
        return amountIn;
    }

    /* ==================== Private Functions ==================== */

    /**
     * @notice Execute a swap against the in memory exchange and write
     *         the new exchange state to storage.
     * @param exchangeId The id of the exchange
     * @param tokenIn The token to be sold
     * @param scaledAmountIn The amount of tokenIn to be sold scaled to 18 decimals
     * @param scaledAmountOut The amount of tokenOut to be bought scaled to 18 decimals
     */
    function executeSwap(
        bytes32 exchangeId,
        address tokenIn,
        uint256 scaledAmountIn,
        uint256 scaledAmountOut
    ) internal {
        PoolExchange memory exchange = getPoolExchange(exchangeId);
        if (tokenIn == exchange.reserveAsset) {
            exchange.reserveBalance += scaledAmountIn;
            exchange.tokenSupply += scaledAmountOut;
        } else {
            exchange.reserveBalance -= scaledAmountOut;
            exchange.tokenSupply -= scaledAmountIn;
        }
        exchanges[exchangeId].reserveBalance = exchange.reserveBalance;
        exchanges[exchangeId].tokenSupply = exchange.tokenSupply;
    }

    /**
     * @notice Calculate amountIn of tokenIn for a given amountOut of tokenOut
     * @param exchange The exchange to operate on
     * @param tokenIn The token to be sold
     * @param tokenOut The token to be bought
     * @param scaledAmountOut The amount of tokenOut to be bought scaled to 18 decimals
     * @return scaledAmountIn The amount of tokenIn to be sold scaled to 18 decimals
     */
    function _getAmountIn(
        PoolExchange memory exchange,
        address tokenIn,
        address tokenOut,
        uint256 scaledAmountOut
    )
        internal
        view
        verifyExchangeTokens(tokenIn, tokenOut, exchange)
        returns (uint256 scaledAmountIn)
    {
        if (tokenIn == exchange.reserveAsset) {
            scaledAmountIn = fundCost(
                exchange.tokenSupply,
                exchange.reserveBalance,
                exchange.reserveRatio,
                scaledAmountOut
            );
        } else {
            scaledAmountIn = fundSupplyAmount(
                exchange.tokenSupply,
                exchange.reserveBalance,
                exchange.reserveRatio,
                scaledAmountOut
            );

            scaledAmountIn =
                (scaledAmountIn * MAX_WEIGHT) /
                (MAX_WEIGHT - exchange.exitContribution);
        }
    }

    /**
     * @notice Calculate amountOut of tokenOut received for a given amountIn of tokenIn
     * @param exchange The exchange to operate on
     * @param tokenIn The token to be sold
     * @param tokenOut The token to be bought
     * @param scaledAmountIn The amount of tokenIn to be sold scaled to 18 decimals
     * @return scaledAmountOut The amount of tokenOut to be bought scaled to 18 decimals
     */
    function _getAmountOut(
        PoolExchange memory exchange,
        address tokenIn,
        address tokenOut,
        uint256 scaledAmountIn
    )
        internal
        view
        verifyExchangeTokens(tokenIn, tokenOut, exchange)
        returns (uint256 scaledAmountOut)
    {
        if (tokenIn == exchange.reserveAsset) {
            scaledAmountOut = purchaseTargetAmount(
                exchange.tokenSupply,
                exchange.reserveBalance,
                exchange.reserveRatio,
                scaledAmountIn
            );
        } else {
            scaledAmountIn =
                (scaledAmountIn * (MAX_WEIGHT - exchange.exitContribution)) /
                MAX_WEIGHT;
            scaledAmountOut = saleTargetAmount(
                exchange.tokenSupply,
                exchange.reserveBalance,
                exchange.reserveRatio,
                scaledAmountIn
            );
        }
    }

    /**
     * @notice Valitates a PoolExchange's parameters and configuration
     * @dev Reverts if not valid
     * @param exchange The PoolExchange to validate
     */
    function validate(PoolExchange memory exchange) private view {
        require(exchange.reserveAsset != address(0), "Invalid reserve asset");
        require(
            reserve.isCollateralAsset(exchange.reserveAsset),
            "reserve asset must be a collateral registered with the reserve"
        );
        require(exchange.tokenAddress != address(0), "Invalid token address");
        require(
            reserve.isStableAsset(exchange.tokenAddress),
            "token must be a stable registered with the reserve"
        );
        require(exchange.reserveRatio > 1, "Invalid reserve ratio");
        require(exchange.reserveRatio <= MAX_WEIGHT, "Invalid reserve ratio");
        require(
            exchange.exitContribution <= MAX_WEIGHT,
            "Invalid exit contribution"
        );
    }
}
