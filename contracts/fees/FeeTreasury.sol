// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale ERC20
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @notice Interface minimale du staking OPND
interface IStakingOPND {
    function distributeReward(uint256 reward) external;
}

/// @notice Interface minimale du SwapRouter Uniswap V3 (exactInputSingle)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Interface minimale de la factory Uniswap V3
interface IUniswapV3Factory {
    function owner() external view returns (address);

    function setOwner(address _owner) external;

    /// @notice Configure le partage des fees protocole pour une pool donnée.
    /// @dev Dans Uniswap V3 officiel, seule la factory peut appeler setFeeProtocol sur la pool.
    function setFeeProtocol(address pool, uint8 feeProtocol0, uint8 feeProtocol1) external;

    /// @notice Récupère les fees protocole accumulés dans une pool.
    function collectProtocol(
        address pool,
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);
}

/// @notice Interface minimale de la pool Uniswap V3 (pour vérifier la factory)
interface IUniswapV3Pool {
    function factory() external view returns (address);
}

/// @title FeeTreasury - Trésorerie Opendrome + gestion des protocol fees
/// @notice Reçoit les protocol fees des pools V3, les convertit en OPND et les envoie au staking.
/// @dev Ce contrat assume aussi le rôle "owner" de la factory Uniswap V3 (après transfert d'owner),
///      ce qui lui permet de:
///        - définir les protocol fees à 10% pour chaque pool
///        - collecter les protocol fees des pools
///      Pas d'owner humain, pas d'admin :
///        - owner(factory) => ce contrat
///        - n'importe qui peut appeler setProtocolFeeForPool() et collectProtocolFees()
contract FeeTreasury {
    IERC20 public immutable opnd;          // Token OPND
    IStakingOPND public immutable staking; // Contrat StakingOPND
    ISwapRouter public immutable router;   // Uniswap V3 SwapRouter sur HyperEVM
    IUniswapV3Factory public immutable factory; // Factory Uniswap V3 utilisée par Opendrome

    /// @notice Token natif wrappé (ex: WETH, WHYPE selon la chain)
    address public immutable wrappedNative;

    /// @notice 10% des swap fees (1/10 des fees LP)
    /// @dev Dans Uniswap V3, feeProtocol est un diviseur sur les fees LP.
    ///      feeProtocol = 10 => 1/10 des fees va au protocole.
    uint8 public constant FEE_PROTOCOL = 10;

    /// @notice Pour éviter de re-configurer plusieurs fois la même pool
    mapping(address => bool) public feeSetForPool;

    /// --------- Reentrancy guard minimal ----------
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    event ProtocolFeeSet(address indexed pool, uint8 feeProtocol0, uint8 feeProtocol1);
    event ProtocolFeesCollected(address indexed pool, uint128 amount0, uint128 amount1);
    event ConvertedAndDistributed(
        address indexed caller,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 opndOut,
        uint24 poolFee
    );

    constructor(
        address _opnd,
        address _staking,
        address _router,
        address _wrappedNative,
        address _factory
    ) {
        require(_opnd != address(0), "opnd=0");
        require(_staking != address(0), "staking=0");
        require(_router != address(0), "router=0");
        require(_wrappedNative != address(0), "wrappedNative=0");
        require(_factory != address(0), "factory=0");

        opnd = IERC20(_opnd);
        staking = IStakingOPND(_staking);
        router = ISwapRouter(_router);
        wrappedNative = _wrappedNative;
        factory = IUniswapV3Factory(_factory);

        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /*//////////////////////////////////////////////////////////////
                        GESTION DES PROTOCOL FEES
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure le protocol fee (10%) pour une pool donnée.
    /// @dev Doit être appelée APRÈS création de la pool.
    ///      Cette fonction est ouverte à tous : n'importe qui peut l'appeler.
    ///      Prérequis: la factory doit avoir ce contrat comme owner.
    function setProtocolFeeForPool(address pool) external nonReentrant {
        require(pool != address(0), "pool=0");
        require(!feeSetForPool[pool], "already set");

        // Vérifie que la pool appartient bien à notre factory
        require(IUniswapV3Pool(pool).factory() == address(factory), "wrong factory");

        // Appel Uniswap V3: la factory appelle setFeeProtocol sur la pool
        factory.setFeeProtocol(pool, FEE_PROTOCOL, FEE_PROTOCOL);

        feeSetForPool[pool] = true;

        emit ProtocolFeeSet(pool, FEE_PROTOCOL, FEE_PROTOCOL);
    }

    /// @notice Collecte les protocol fees d'une pool vers FeeTreasury.
    /// @dev Ouvert à tous, pas besoin d'admin. Les tokens restent dans ce contrat,
    ///      prêts à être convertis en OPND via convertAndDistribute().
    function collectProtocolFees(address pool) external nonReentrant {
        require(pool != address(0), "pool=0");
        require(IUniswapV3Pool(pool).factory() == address(factory), "wrong factory");

        (uint128 amount0, uint128 amount1) = factory.collectProtocol(
            pool,
            address(this),
            type(uint128).max,
            type(uint128).max
        );

        emit ProtocolFeesCollected(pool, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                 CONVERSION DES FEES -> OPND -> STAKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Convertit `amountIn` d'un token reçu en OPND via Uniswap V3,
    ///         puis envoie les OPND au staking sous forme de rewards.
    /// @dev Cette fonction est ouverte à tous : n'importe qui peut "harvest".
    ///
    /// @param tokenIn  Le token à convertir (doit être déjà détenu par ce contrat)
    /// @param amountIn Montant de tokenIn à swaper
    /// @param poolFee  Fee tier de la pool V3 (ex: 500, 3000, 10000)
    function convertAndDistribute(
        address tokenIn,
        uint256 amountIn,
        uint24 poolFee
    )
        external
        nonReentrant
    {
        require(tokenIn != address(0), "tokenIn=0");
        require(amountIn > 0, "amountIn=0");

        IERC20 token = IERC20(tokenIn);

        // Vérification simple : le contrat doit posséder au moins amountIn
        require(token.balanceOf(address(this)) >= amountIn, "insufficient balance");

        uint256 opndBefore = opnd.balanceOf(address(this));
        uint256 opndReceived;

        if (tokenIn == address(opnd)) {
            // Si on a déjà de l'OPND, pas besoin de swap.
            opndReceived = amountIn;
        } else {
            // Approve le router pour utiliser nos tokens
            require(
                token.approve(address(router), amountIn),
                "approve failed"
            );

            // Swap tokenIn -> OPND via exactInputSingle
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: address(opnd),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,        // à améliorer plus tard pour limiter le slippage
                sqrtPriceLimitX96: 0        // pas de limite de prix
            });

            router.exactInputSingle(params);

            uint256 opndAfter = opnd.balanceOf(address(this));
            require(opndAfter > opndBefore, "no OPND received");

            opndReceived = opndAfter - opndBefore;
        }

        require(opndReceived > 0, "opndReceived=0");

        // Approve le staking pour prendre opndReceived
        require(
            opnd.approve(address(staking), opndReceived),
            "approve staking failed"
        );

        // Envoie les OPND comme rewards au staking
        staking.distributeReward(opndReceived);

        emit ConvertedAndDistributed(msg.sender, tokenIn, amountIn, opndReceived, poolFee);
    }
}
