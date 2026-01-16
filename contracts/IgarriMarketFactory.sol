// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import "./base/Proxy.sol";

/**
 * @title IgarriMarketFactory
 * @notice Factory contract for deploying Igarri Market instances
 * @dev Enhanced version with better error handling, events, and public interface
 */
contract IgarriMarketFactory {
    mapping (address => bool) public deployer;

    // Events for transparency and indexing
    event ProxyDeployed(
        address indexed proxy,
        address indexed singleton,
        bytes32 salt,
        address deployer
    );

    // Custom errors for gas efficiency and better UX
    error SingletonNotDeployed();
    error ProxyDeploymentFailed();
    error InitializationFailed();
    error InvalidOwner();
    error InvalidSingleton();

    constructor() {
        deployer[msg.sender] = true;
    }

    modifier onlyDeployer() {
        require(deployer[msg.sender], "Not the deployer");
        _;
    }

    /**
     * @notice Deploys a new Igarri Market Proxy with specified parameters
     * @param singleton The implementation contract address
     * @param initializer Initialization call data
     * @param salt Unique salt for deterministic address generation
     * @return proxy The deployed proxy address
     */
    function deployMarket(
        address singleton,
        bytes memory initializer,
        bytes32 salt
    ) public onlyDeployer returns (Proxy proxy) {
        // Input validation
        if (!isContract(singleton)) revert SingletonNotDeployed();

        // Prepare deployment data
        bytes memory deploymentData = abi.encodePacked(
            type(Proxy).creationCode,
            abi.encode(singleton)
        );

        // Deploy using CREATE2
        assembly {
            proxy := create2(
                0x0,
                add(0x20, deploymentData),
                mload(deploymentData),
                salt
            )
        }

        // Check deployment success
        if (address(proxy) == address(0)) revert ProxyDeploymentFailed();

        // Initialize if initializer provided
        if (initializer.length > 0) {
            assembly {
                if eq(
                    call(
                        gas(),
                        proxy,
                        0,
                        add(initializer, 0x20),
                        mload(initializer),
                        0,
                        0
                    ),
                    0
                ) {
                    revert(0, 0)
                }
            }
        }

        emit ProxyDeployed(address(proxy), singleton, salt, msg.sender);
    }

    /**
     * @notice Calculates the deterministic address of a proxy before deployment
     * @param singleton The implementation contract address
     * @param salt Salt for deterministic address generation
     * @return proxyAddress The calculated proxy address
     */
    function calculateProxyAddress(
        address singleton,
        bytes32 salt
    ) external view returns (address proxyAddress) {
        bytes memory deploymentData = abi.encodePacked(
            type(Proxy).creationCode,
            abi.encode(singleton)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(deploymentData)
            )
        );

        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Checks if a proxy exists at the calculated address
     * @param singleton The implementation contract address
     * @param salt Salt used for deployment
     * @return exists True if proxy exists at calculated address
     */
    function proxyExists(
        address singleton,
        bytes32 salt
    ) external view returns (bool exists) {
        address calculatedAddress = this.calculateProxyAddress(singleton, salt);
        return isContract(calculatedAddress);
    }

    /**
     * @notice Returns true if `account` is a contract.
     * @dev This function will return false if invoked during the constructor of a contract,
     * as the code is not actually created until after the constructor finishes.
     * @param account The address being queried
     * @return True if `account` is a contract
     */
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @notice Gets the creation code hash for proxy address calculation
     * @dev Useful for off-chain address calculation
     * @return hash The creation code hash
     */
    function getProxyCreationCodeHash() external pure returns (bytes32 hash) {
        return keccak256(type(Proxy).creationCode);
    }

    /**
     * @notice Adds a new deployer to the factory
     * @param _deployer The address of the deployer to add
     */
    function addDeployer(address _deployer) external onlyDeployer {
        deployer[_deployer] = true;
    }
}