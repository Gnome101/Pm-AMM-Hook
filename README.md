# Pm-AMM-Hook

This repository implements a Uniswap v4 hook based on the static PM AMM described in Paradigm’s research paper. The hook introduces probability market AMM mechanics into Uniswap v4, utilizing Solstat for cumulative and probability density function calculations.

# Overview

This hook modifies Uniswap v4’s pool mechanics to incorporate a static PM AMM, leveraging Solstat for statistical computations. The goal is to enable novel liquidity pricing dynamics by integrating probabilistic market making models.

# Key Features
	•	Uniswap v4 Hook – Integrates with Uniswap v4 pools to enable custom liquidity behavior.
	•	Static PM AMM Implementation – Based on the mathematical framework outlined in the Paradigm paper.
	•	Solstat for CDF & PDF Calculations – Used to compute probability distributions within the hook.
	•	Built with Foundry – A high-performance smart contract development environment.

# Installation & Setup

Ensure you have Foundry installed. If not, install it using:

curl -L https://foundry.paradigm.xyz | bash
foundryup

## Clone the repository:

git clone https://github.com/Gnome101/Pm-AMM-Hook.git
cd Pm-AMM-Hook
forge install

# Usage

## Compiling the Contract

### To build the project:

forge build --via-ir

### Run tests using:

forge test --via-if

Contract Details

# Hook Implementation
	•	Location: src/Hook.sol
	•	Functionality: Implements a Uniswap v4 hook utilizing probability-based AMM pricing.

# Dependencies
	•	Uniswap v4 Core
	•	Solstat – Used for statistical calculations such as cumulative distribution functions (CDF) and probability density functions (PDF).
    •.  FixedPointLib - Used solmate fixed point library for optimized math.

# References
 https://www.paradigm.xyz/2024/11/pm-amm

# License

This project is licensed under the MIT License. See the LICENSE file for details.
