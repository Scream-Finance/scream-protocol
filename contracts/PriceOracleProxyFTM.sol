pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./CErc20.sol";
import "./CToken.sol";
import "./PriceOracle.sol";
import "./Exponential.sol";
import "./EIP20Interface.sol";

interface V1PriceOracleInterface {
    function assetPrices(address asset) external view returns (uint);
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface IStdReference {
    /// A structure returned whenever someone requests for standard reference data.
    struct ReferenceData {
        uint256 rate; // base/quote exchange rate, multiplied by 1e18.
        uint256 lastUpdatedBase; // UNIX epoch of the last time when base price gets updated.
        uint256 lastUpdatedQuote; // UNIX epoch of the last time when quote price gets updated.
    }

    /// Returns the price data for the given base/quote pair. Revert if not available.
    function getReferenceData(string calldata _base, string calldata _quote)
        external
        view
        returns (ReferenceData memory);

    /// Similar to getReferenceData, but with multiple base/quote pairs at once.
    function getRefenceDataBulk(string[] calldata _bases, string[] calldata _quotes)
        external
        view
        returns (ReferenceData[] memory);
}

interface IKeep3rV2Oracle {
    function current(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut, uint lastUpdatedAgo);
    function quote(address tokenIn, uint amountIn, address tokenOut, uint points) external view returns (uint amountOut, uint lastUpdatedAgo); 
}

interface IXToken {
    function decimals() external view returns (uint8);
    function getShareValue() external view returns (uint256);
}

contract PriceOracleProxyFTM is PriceOracle, Exponential {
    /// @notice Admin address
    address public admin;

    /// @notice BAND reference
    IStdReference public ref;

    /// @notice Chainlink Aggregators
    mapping(address => AggregatorV3Interface) public aggregators;

    /// @notice Keep3r Oracles
    mapping(address => IKeep3rV2Oracle) public keep3rs;

    /// @notice Keep3r Oracles
    mapping(address => address) public xTokenUnderlyings;

    /// @notice The v1 price oracle, maintain by CREAM
    V1PriceOracleInterface public v1PriceOracle;

    /// @notice The mapping records the crToken and its underlying symbol that we use for BAND reference
    ///         It's not necessarily equals to the symbol in the underlying contract
    mapping(address => string) public underlyingSymbols;

    /// @notice The max price diff that we could tolerant
    uint public maxPriceDiff = 0.1e18;

    /// @notice Quote symbol we used for BAND reference contract
    string public constant QUOTE_SYMBOL = "USD";

    /// @notice WFTM address
    address public constant WFTM_ADDRESS = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    /// @notice scWFTM address
    address public constant SCWFTM_ADDRESS = address(0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d);


    /**
     * @param admin_ The address of admin to set aggregators
     * @param v1PriceOracle_ The address of the v1 price oracle, which will continue to operate and hold prices for collateral assets
     * @param reference_ The price reference contract, which will be served for one of our primary price source on Fantom
     */
    constructor(address admin_, address v1PriceOracle_, address reference_) public {
        admin = admin_;
        v1PriceOracle = V1PriceOracleInterface(v1PriceOracle_);
        ref = IStdReference(reference_);
    }

    /**
     * @notice Get the underlying price of a listed cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18)
     */
    function getUnderlyingPrice(CToken cToken) public view returns (uint) {
        address cTokenAddress = address(cToken);

        uint chainLinkPrice = getPriceFromChainlink(cTokenAddress);
        uint bandPrice = getPriceFromBAND(cTokenAddress);
        uint keep3rPrice = getPriceFromKeep3r(cTokenAddress);

        if (chainLinkPrice != 0 && bandPrice != 0) {
            checkPriceDiff(chainLinkPrice, bandPrice);

            // Return the average of two prices.
            return div_(add_(chainLinkPrice, bandPrice), 2);
        }
        if (chainLinkPrice != 0) {
            return chainLinkPrice;
        }
        if (bandPrice != 0) {
            return bandPrice;
        }

        if (keep3rPrice != 0) {
            return keep3rPrice;
        }

        return getPriceFromV1(cTokenAddress);
    }

    /*** Internal fucntions ***/

    /**
     * @notice Check the max diff between two prices.
     * @param price1 Price 1
     * @param price1 Price 2
     */
    function checkPriceDiff(uint price1, uint price2) internal view {
        uint min = price1 < price2 ? price1 : price2;
        uint max = price1 < price2 ? price2 : price1;

        // priceCap = min * (1 + maxPriceDiff)
        uint onePlusMaxDiffMantissa = add_(1e18, maxPriceDiff);
        uint priceCap = mul_(min, Exp({mantissa : onePlusMaxDiffMantissa}));
        require(priceCap > max, "too much diff between price feeds");
    }

    /**
     * @notice Try to get the underlying price of a cToken from Chain Link.
     * @param cTokenAddress The token to get the underlying price of
     * @return The price. Return 0 if the aggregator is not set.
     */
    function getPriceFromChainlink(address cTokenAddress) internal view returns (uint) {
        AggregatorV3Interface aggregator = aggregators[cTokenAddress];
        if (address(aggregator) != address(0)) {
            ( , int answer, , , ) = aggregator.latestRoundData();

            // It's fine for price to be 0. We have three price feeds.
            if (answer == 0) {
                return 0;
            }

            // Extend the decimals to 1e18.
            uint price = mul_(uint(answer), 10**(18 - uint(aggregator.decimals())));
            return getNormalizedPrice(price, cTokenAddress);
        }
        return 0;
    }

    /**
     * @notice Try to get the underlying price of a cToken from BAND protocol.
     * @param cTokenAddress The token to get the underlying price of
     * @return The price. Return 0 if the undelrying sumbol is not set.
     */
    function getPriceFromBAND(address cTokenAddress) internal view returns (uint) {
        bytes memory symbol = bytes(underlyingSymbols[cTokenAddress]);
        if (symbol.length != 0) {
            IStdReference.ReferenceData memory data = ref.getReferenceData(string(symbol), QUOTE_SYMBOL);
            // Price from BAND is always 1e18 base.
            return getNormalizedPrice(data.rate, cTokenAddress);
        }
        return 0;
    }


    /**
     * @notice Try to get the underlying price of a cToken from Keep3r.
     * @param cTokenAddress The token to get the underlying price of
     * @return The price. Return 0 if the keep3r is not set.
     */
    function getPriceFromKeep3r(address cTokenAddress) public view returns (uint) {
        IKeep3rV2Oracle keep3r = keep3rs[cTokenAddress];
        address xTokenUnderlying = xTokenUnderlyings[cTokenAddress]; 
        if (address(keep3r) != address(0)) {
            uint answer;
            //check if collateral is a xToken
            if (xTokenUnderlying != address(0)) {
                IXToken xToken = IXToken(CErc20(cTokenAddress).underlying());
                (uint tempAnswer, ) = keep3r.quote(xTokenUnderlying, 1, WFTM_ADDRESS, 2);
                answer = div_(mul_(tempAnswer, uint(xToken.getShareValue())), 10**uint(xToken.decimals()));
            } else {
                (answer, ) = keep3r.quote(CErc20(cTokenAddress).underlying(), 1, WFTM_ADDRESS, 2);
            }


            // It's fine for price to be 0. We have three price feeds.
            if (answer == 0) {
                return 0;
            }
            //multiply by wftm price in USD
            uint wftmPrice = getUnderlyingPrice(CToken(SCWFTM_ADDRESS));

            uint price = mul_(uint(answer), wftmPrice);

            return getNormalizedPrice(price, cTokenAddress);
        }
        return 0;
    }

    /**
     * @notice Normalize the price according to the underlying decimals.
     * @param price The original price
     * @param cTokenAddress The cToken address
     * @return The normalized price.
     */
    function getNormalizedPrice(uint price, address cTokenAddress) internal view returns (uint) {
        uint underlyingDecimals = EIP20Interface(CErc20(cTokenAddress).underlying()).decimals();
        return mul_(price, 10**(18 - underlyingDecimals));
    }

    /**
     * @notice Get price from v1 price oracle
     * @param cTokenAddress The token to get the underlying price of
     * @return The underlying price.
     */
    function getPriceFromV1(address cTokenAddress) internal view returns (uint) {
        address underlying = CErc20(cTokenAddress).underlying();
        return v1PriceOracle.assetPrices(underlying);
    }

    /*** Admin fucntions ***/

    event AdminUpdated(address admin);
    event MaxPriceDiffUpdated(uint maxDiff);
    event AggregatorUpdated(address cTokenAddress, address source);
    event UnderlyingSymbolUpdated(address cTokenAddress, string symbol);
    event Keep3rUpdated(address cTokenAddress, address keep3r);
    event xTokenUnderlyingUpdated(address cTokenAddress, address xTokenUnderlying);


    function _setAdmin(address _admin) external {
        require(msg.sender == admin, "only the admin may set the new admin");
        admin = _admin;
        emit AdminUpdated(_admin);
    }

    function _setMaxPriceDiff(uint _maxPriceDiff) external {
        require(msg.sender == admin, "only the admin may set the max price diff");
        maxPriceDiff = _maxPriceDiff;
        emit MaxPriceDiffUpdated(_maxPriceDiff);
    }

    function _setAggregators(address[] calldata cTokenAddresses, address[] calldata sources) external {
        require(msg.sender == admin, "only the admin may set the aggregators");
        for (uint i = 0; i < cTokenAddresses.length; i++) {
            aggregators[cTokenAddresses[i]] = AggregatorV3Interface(sources[i]);
            emit AggregatorUpdated(cTokenAddresses[i], sources[i]);
        }
    }

    function _setUnderlyingSymbols(address[] calldata cTokenAddresses, string[] calldata symbols) external {
        require(msg.sender == admin, "only the admin may set the undelrying symbols");
        for (uint i = 0; i < cTokenAddresses.length; i++) {
            underlyingSymbols[cTokenAddresses[i]] = symbols[i];
            emit UnderlyingSymbolUpdated(cTokenAddresses[i], symbols[i]);
        }
    }

    function _setKeep3rOracles(address[] calldata cTokenAddresses, address[] calldata sources) external {
        require(msg.sender == admin, "only the admin may set the keeper oracles");
        for (uint i = 0; i < cTokenAddresses.length; i++) {
            keep3rs[cTokenAddresses[i]] = IKeep3rV2Oracle(sources[i]);
            emit Keep3rUpdated(cTokenAddresses[i], sources[i]);
        }
    }

    function _setXToken(address[] calldata cTokenAddresses, address[] calldata sources) external {
        require(msg.sender == admin, "only the admin may set the keeper oracles");
        for (uint i = 0; i < cTokenAddresses.length; i++) {
            xTokenUnderlyings[cTokenAddresses[i]] = sources[i];
            emit xTokenUnderlyingUpdated(cTokenAddresses[i], sources[i]);
        }
    }
}